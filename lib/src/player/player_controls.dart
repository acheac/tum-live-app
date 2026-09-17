/// The chrome that floats over the picture: seek bar, play button, clock.
///
/// Split out from [LecturePlayer] because the two have genuinely different
/// jobs. This file knows nothing about loading a video or about the network —
/// hand it an initialised [VideoPlayerController] and it draws controls for it.
///
/// The behaviour follows Bilibili's player. With a mouse, the bar only wakes up
/// when the pointer is near the bottom of the picture, and it stays up while you
/// are paused or actually touching it. With a finger:
///
/// ```
///   tap              show or hide the controls
///   double tap       play / pause, leaving the controls as they were
///   swipe sideways   scrub: the bar rises and the target time shows in
///                    the centre
/// ```
///
/// The three share one surface, which makes the gesture arena the interesting
/// part of this file — see [_PlayerChromeState._awaitingSecondTap],
/// [_PlayerChromeState._scrubTravel], and the layer comment in
/// [_PlayerChromeState.build].
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../common/formatting.dart';
import 'player_preferences.dart';

/// How far a popup menu opened from the control bar has to be lifted to sit
/// *above* the button rather than on top of it.
///
/// [PopupMenuPosition.over] anchors the menu's top edge to the button's, so it
/// grows downwards — and the bar is already at the bottom of the video, so
/// Material slides the whole menu up until it covers the very icon that opened
/// it. Raising it by its own height puts its bottom edge just above the button.
///
/// Shared by the two menus in the bar so they cannot drift apart.
double popupMenuLift(int itemCount) =>
    itemCount * popupMenuItemHeight + _popupMenuPadding + _popupMenuGap;

/// Row height for both menus. Tighter than Material's default, because these
/// float over a video rather than sitting on a page.
const double popupMenuItemHeight = 34;

/// The menu's own vertical padding, above the first row and below the last.
const double _popupMenuPadding = 16;

/// Breathing room between the menu and the button it belongs to.
const double _popupMenuGap = 8;

/// Both bar menus are pinned to one width, and their buttons to another, which
/// is what lets the menus be centred on their buttons by arithmetic. Measuring
/// the button instead would mean laying it out before knowing where to put the
/// menu, and a popup's offset has to be decided up front.
const double popupMenuWidth = 132;
const double popupMenuButtonWidth = 40;
const double popupMenuButtonHeight = 36;

/// Opens a control-bar menu centred above the widget that [context] belongs to.
///
/// [PopupMenuButton]'s own `offset` cannot do this. Material anchors the menu
/// to whichever side of the button has more room — left edge to left edge near
/// the left of the screen, right edge to right edge near the right — so a fixed
/// shift centres the menu on one side of the screen and pushes it further off
/// on the other. Handing it a position rect exactly as wide as the menu makes
/// both branches land in the same place, which is this one.
Future<T?> showBarMenu<T>({
  required BuildContext context,
  required List<PopupMenuEntry<T>> items,
  int rowCount = 0,
  T? initialValue,
}) {
  final RenderBox button = context.findRenderObject()! as RenderBox;
  final RenderBox overlay =
      Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
  final Offset topLeft = button.localToGlobal(Offset.zero, ancestor: overlay);

  final double centreX = topLeft.dx + button.size.width / 2;
  const double screenPadding = 8;
  final double left = (centreX - popupMenuWidth / 2).clamp(
    screenPadding,
    math.max(
      screenPadding,
      overlay.size.width - popupMenuWidth - screenPadding,
    ),
  );
  final double top =
      topLeft.dy - popupMenuLift(rowCount == 0 ? items.length : rowCount);

  return showMenu<T>(
    context: context,
    initialValue: initialValue,
    constraints: const BoxConstraints.tightFor(width: popupMenuWidth),
    position: RelativeRect.fromLTRB(
      left,
      top,
      overlay.size.width - left - popupMenuWidth,
      overlay.size.height - top,
    ),
    items: items,
  );
}

/// A small rounded rectangle used as the seek handle, instead of Material's
/// default circle. Painted by the Slider at the current position.
class RectangleThumb extends SliderComponentShape {
  const RectangleThumb();

  static const Size _size = Size(7, 18);

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => _size;

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    // Grows slightly while dragging so the grab is visible.
    final double grow = 1 + 0.25 * activationAnimation.value;
    final Rect rect = Rect.fromCenter(
      center: center,
      width: _size.width * grow,
      height: _size.height * grow,
    );
    context.canvas
      ..drawRRect(
        RRect.fromRectAndRadius(rect.inflate(1), const Radius.circular(3)),
        Paint()..color = Colors.black.withValues(alpha: 0.45),
      )
      ..drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2.5)),
        Paint()..color = sliderTheme.thumbColor ?? Colors.white,
      );
  }
}

/// Picture plus auto-hiding controls for an already-initialised controller.
class PlayerChrome extends StatefulWidget {
  const PlayerChrome({
    super.key,
    required this.controller,
    this.onPositionChanged,
    this.extraControls = const <Widget>[],
    this.title,
    this.onBack,
    this.isFullscreen = false,
    this.onToggleFullscreen,
    this.onPlayingChanged,
    this.overlay,
    this.overlayAspectRatio = 16 / 9,
  });

  final VideoPlayerController controller;

  /// Fired on every position update while playing. The player page uses this to
  /// report watch progress; throttling is the listener's job, not ours.
  final void Function(Duration position, Duration duration)? onPositionChanged;

  /// Fired when playback starts or stops — on the change only, not on every
  /// frame like [onPositionChanged]. The page uses it to animate the marker on
  /// the lecture currently playing.
  final ValueChanged<bool>? onPlayingChanged;

  /// A second picture to inset over the bottom-right of the first — the camera
  /// in the fused source. Sized and framed here; kept in sync by whoever owns
  /// its controller.
  final Widget? overlay;

  /// The inset's shape. Needed here because the inset is positioned and
  /// resized from this side, so its height cannot be left to the child.
  final double overlayAspectRatio;

  /// Extra buttons for the right-hand side of the control bar, e.g. the
  /// camera-angle switcher. Shown only in fullscreen — see [isFullscreen].
  final List<Widget> extraControls;

  /// Shown in the overlay across the top of the picture.
  final String? title;

  /// Back action for the overlay. Null hides the button.
  final VoidCallback? onBack;

  /// Whether the picture currently has the whole screen.
  ///
  /// In a 16:9 slot the bar is only about 560dp wide and sits on top of the
  /// video, so it earns its keep by holding the few things you reach for
  /// mid-lecture and nothing else. [extraControls] and the speed menu are
  /// settings — you pick them once and go back to watching — so they wait for
  /// fullscreen, where there is room for them.
  final bool isFullscreen;

  /// Enters or leaves fullscreen. Null hides the button, which is what the
  /// widget tests and any non-rotating host get.
  final VoidCallback? onToggleFullscreen;

  @override
  State<PlayerChrome> createState() => _PlayerChromeState();
}

class _PlayerChromeState extends State<PlayerChrome> {
  /// Whether the control bar is currently on screen.
  bool _controlsVisible = true;

  /// True while the pointer rests on the control bar itself. We skip the
  /// auto-hide in that case so the bar does not vanish as you reach for a button.
  bool _pointerOnControls = false;

  /// How long the bar stays up with no pointer movement before hiding.
  static const Duration _autoHideDelay = Duration(seconds: 3);

  /// The bar only wakes up when the pointer is inside this strip along the
  /// bottom of the picture. Moving around the upper area leaves it hidden.
  static const double _hotZoneMinHeight = 120;
  static const double _hotZoneFraction = 0.22;

  /// Seconds the user is dragging the handle to, or null when not dragging.
  /// While set, the seek bar and the clock follow the finger instead of
  /// playback, otherwise the handle would snap back on every frame.
  double? _dragSeconds;

  /// Where a just-released drag asked to go. Held until playback actually
  /// reports arriving there, because seekTo() is async and the 100ms position
  /// poll can still be in flight carrying a pre-seek value. Without this the
  /// handle snaps back to the old spot for a frame, then jumps forward.
  double? _pendingSeekSeconds;

  Timer? _seekSettleTimer;

  /// After the seek resolves, ignore playback for this long so any position
  /// poll already in flight lands and is discarded. Cannot key off the value
  /// instead: seekTo's own update reports exactly the target, so it is
  /// indistinguishable from a genuine one.
  static const Duration _seekSettleWindow = Duration(milliseconds: 400);

  /// Safety net in case the platform never answers the seek at all.
  static const Duration _seekSafetyTimeout = Duration(seconds: 5);

  Timer? _hideTimer;

  /// Seconds a horizontal swipe across the picture is aiming at, or null when
  /// no swipe is in progress. Distinct from [_dragSeconds], which belongs to
  /// the seek bar's own handle — the two never run at once, because the bar is
  /// hidden for the whole gesture.
  double? _scrubSeconds;

  /// Where the swipe began, so the readout can show a signed offset rather
  /// than only an absolute time.
  double? _scrubOriginSeconds;

  /// Whether the video was playing when the swipe started, and so should be
  /// playing again when it ends. Scrubbing a moving picture fights the finger.
  bool _resumeAfterScrub = false;

  /// Horizontal distance travelled since the gesture began, and whether it has
  /// passed [_scrubSlop] and become a real scrub.
  ///
  /// The drag recognizer can win the arena for a gesture that never moves — a
  /// plain tap, including one on a control — and firing start/end on that would
  /// pause and resume the video for every tap. So nothing happens until the
  /// finger has actually travelled.
  double _scrubTravel = 0;
  bool _scrubEngaged = false;

  /// How far the finger must move sideways before it counts as scrubbing.
  static const double _scrubSlop = 8;

  /// Whether a tap just landed and a second one would pair with it.
  ///
  /// Flutter's own [GestureDetector.onDoubleTap] cannot be used here: it holds
  /// the tap back for [_doubleTapWindow] to find out whether a second is
  /// coming, so the controls appeared a third of a second after the finger
  /// lifted — long enough to feel broken. Detecting the pair by hand lets the
  /// first tap act immediately and the second one correct it, which is the
  /// order the user perceives anyway.
  bool _awaitingSecondTap = false;
  Timer? _secondTapTimer;

  /// How close two taps must be to count as one double tap, and so also how
  /// long a lone tap waits before it is believed.
  ///
  /// Shorter than Flutter's own [kDoubleTapTimeout] of 300ms. The bar cannot
  /// both appear the instant a finger lifts and stay away during a double tap —
  /// acting immediately means a double tap flashes it up and pulls it back
  /// again. So the tap waits, and this is the smallest wait that still reads
  /// as a double tap for an ordinary hand. Lengthen it and lone taps feel
  /// sluggish; shorten it and a lazy double tap breaks into two single ones.
  static const Duration _doubleTapWindow = Duration(milliseconds: 250);

  /// A swipe clean across the picture covers this much of the video, so half a
  /// screen is the 30% jump the gesture is modelled on.
  static const double _scrubFractionPerScreen = 0.6;

  /// ...but clamped to this many seconds per logical pixel. Pure proportional
  /// mapping breaks down at both ends of the range this app actually sees: on a
  /// 90-minute lecture it puts 8 seconds under every pixel, so nudging back to
  /// a missed sentence is impossible, and on a 3-minute clip it is so fine the
  /// gesture feels broken. The seek bar is already the coarse control; this one
  /// earns its place by being precise.
  static const double _minScrubRate = 0.05;
  static const double _maxScrubRate = 1.0;

  /// Whether the picture is scaled up to fill the screen, cropping what will
  /// not fit. Off by default: cropping is a choice, not something to do to
  /// someone's lecture unasked. See [_buildPicture].
  bool _fillScreen = false;

  /// The speeds the menu offers, Bilibili-style.
  static const List<double> _speeds = <double>[0.5, 1.0, 1.25, 1.5, 2.0];
  double _speed = 1.0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleControllerUpdate);
    // Flash the bar once, then start the hide countdown. Without this the bar
    // would stay up forever until the first mouse event.
    _revealControls();
    unawaited(_restoreInset());
  }

  Future<void> _restoreInset() async {
    final CameraInset? stored = await _insetPreference.read();
    if (!mounted || stored == null) return;
    setState(() => _inset = stored);
  }

  @override
  void didUpdateWidget(PlayerChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerUpdate);
      widget.controller.addListener(_handleControllerUpdate);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerUpdate);
    _hideTimer?.cancel();
    _seekSettleTimer?.cancel();
    _secondTapTimer?.cancel();
    super.dispose();
  }

  /// Last reported playing state, so [PlayerChrome.onPlayingChanged] fires on
  /// the edges rather than on every position tick.
  bool _wasPlaying = false;

  void _handleControllerUpdate() {
    final VideoPlayerValue value = widget.controller.value;
    if (!value.isInitialized) return;
    widget.onPositionChanged?.call(value.position, value.duration);
    if (value.isPlaying != _wasPlaying) {
      _wasPlaying = value.isPlaying;
      widget.onPlayingChanged?.call(value.isPlaying);
    }
  }

  /// Schedules handing the handle back to live playback.
  void _armSeekRelease(Duration delay) {
    _seekSettleTimer?.cancel();
    _seekSettleTimer = Timer(delay, () {
      if (!mounted) return;
      setState(() => _pendingSeekSeconds = null);
    });
  }

  /// Shows the control bar and restarts the auto-hide countdown.
  void _revealControls() {
    _hideTimer?.cancel();
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _hideTimer = Timer(_autoHideDelay, _maybeHideControls);
  }

  /// Hides the bar, unless we are paused or the pointer is resting on the bar
  /// (same rule Bilibili uses).
  void _maybeHideControls() {
    if (!mounted) return;
    if (_dragSeconds != null || _pendingSeekSeconds != null) return;
    if (_scrubSeconds != null) return;
    if (_pointerOnControls || !widget.controller.value.isPlaying) return;
    setState(() => _controlsVisible = false);
  }

  /// True when [localY] falls in the bottom strip of a player [height] tall.
  bool _inHotZone(double localY, double height) {
    final double zone = math.max(_hotZoneMinHeight, height * _hotZoneFraction);
    return localY >= height - zone;
  }

  /// Called on every pointer move over the picture. Only the bottom strip
  /// summons the bar; anywhere higher lets it stay away.
  void _handlePointer(Offset localPosition, double height) {
    if (_inHotZone(localPosition.dy, height)) {
      _revealControls();
    } else if (_controlsVisible) {
      // Left the strip: start the countdown rather than snapping it away.
      _hideTimer?.cancel();
      _hideTimer = Timer(_autoHideDelay, _maybeHideControls);
    }
  }

  /// A single tap means different things to a finger and to a mouse.
  ///
  /// A mouse already summons the bar by hovering and, on every desktop player
  /// worth copying, a click toggles playback. Touch has no hover at all, so
  /// there a tap is the only way to ask for the bar — which is what Bilibili's
  /// phone app does, with playback moved to the double tap.
  void _handleTapUp(TapUpDetails details) {
    if (details.kind == PointerDeviceKind.mouse) {
      _togglePlay();
      return;
    }

    if (_awaitingSecondTap) {
      _secondTapTimer?.cancel();
      _awaitingSecondTap = false;
      _handleDoubleTap();
      return;
    }
    // Nothing happens yet. The bar must not appear at all during a double tap,
    // and the only way to know this is not one is to wait the window out.
    _awaitingSecondTap = true;
    _secondTapTimer = Timer(_doubleTapWindow, () {
      _awaitingSecondTap = false;
      if (mounted) _toggleControls();
    });
  }

  void _toggleControls() {
    if (_controlsVisible) {
      _hideTimer?.cancel();
      setState(() => _controlsVisible = false);
    } else {
      _revealControls();
    }
  }

  /// Playback only. The first tap of the pair deliberately left the chrome
  /// untouched, and revealing it now would undo the point of that: the picture
  /// stopping or starting is its own feedback.
  void _handleDoubleTap() => _togglePlay(reveal: false);

  /// Seconds of video per logical pixel of swipe, for a picture [width] wide.
  ///
  /// Proportional to the video's length, then clamped — see [_minScrubRate].
  double _scrubRate(double width) {
    if (width <= 0) return _minScrubRate;
    final double total = widget.controller.value.duration.inMilliseconds / 1000;
    final double proportional = total * _scrubFractionPerScreen / width;
    return proportional.clamp(_minScrubRate, _maxScrubRate);
  }

  /// Only arms the gesture. See [_scrubTravel] for why nothing happens yet.
  void _handleScrubStart() {
    _scrubTravel = 0;
    _scrubEngaged = false;
  }

  /// Takes over playback the moment the finger passes [_scrubSlop].
  void _engageScrub() {
    final VideoPlayerValue value = widget.controller.value;
    _hideTimer?.cancel();
    _resumeAfterScrub = value.isPlaying;
    if (value.isPlaying) widget.controller.pause();
    final double now = value.position.inMilliseconds / 1000;
    setState(() {
      _scrubEngaged = true;
      // Up, and staying up for the whole gesture: the handle sliding along the
      // track is what shows *how far* the swipe has gone, which the centre
      // readout's numbers alone do not convey. They sit at opposite ends of
      // the picture, so neither is in the other's way.
      //
      // _maybeHideControls bails out while a scrub is live, so the countdown
      // cannot pull the bar away mid-swipe.
      _controlsVisible = true;
      _scrubOriginSeconds = now;
      _scrubSeconds = now;
    });
  }

  void _handleScrubUpdate(DragUpdateDetails details, double width) {
    final VideoPlayerValue value = widget.controller.value;
    if (!value.isInitialized || value.duration <= Duration.zero) return;

    if (!_scrubEngaged) {
      _scrubTravel += details.delta.dx;
      if (_scrubTravel.abs() < _scrubSlop) return;
      _engageScrub();
    }
    final double? current = _scrubSeconds;
    if (current == null) return;
    final double total = value.duration.inMilliseconds / 1000;
    final double next = current + details.delta.dx * _scrubRate(width);
    setState(() => _scrubSeconds = next.clamp(0, total));
  }

  Future<void> _handleScrubEnd() async {
    // A gesture that never travelled is someone's tap. Leave it alone.
    if (!_scrubEngaged) return;
    _scrubEngaged = false;
    final double? target = _scrubSeconds;
    if (target == null) return;
    // Hand over to the same pending-seek machinery the bar's handle uses, so
    // the position does not snap back while seekTo is still in flight.
    setState(() {
      _scrubSeconds = null;
      _scrubOriginSeconds = null;
      _pendingSeekSeconds = target;
    });
    _armSeekRelease(_seekSafetyTimeout);
    await widget.controller.seekTo(
      Duration(milliseconds: (target * 1000).round()),
    );
    if (!mounted) return;
    if (_resumeAfterScrub) widget.controller.play();
    _revealControls();
    _armSeekRelease(_seekSettleWindow);
  }

  /// Flips playback. [reveal] summons the control bar with it, which every
  /// caller wants except the double tap — see [_handleDoubleTap].
  void _togglePlay({bool reveal = true}) {
    widget.controller.value.isPlaying
        ? widget.controller.pause()
        : widget.controller.play();
    if (reveal) _revealControls();
  }

  Future<void> _setSpeed(double speed) async {
    setState(() => _speed = speed);
    await widget.controller.setPlaybackSpeed(speed);
    _revealControls();
  }

  /// How far the video has buffered ahead, in seconds.
  double _bufferedSeconds(VideoPlayerValue value) {
    if (value.buffered.isEmpty) return 0;
    return value.buffered.last.end.inMilliseconds / 1000;
  }

  /// Draggable seek bar. The rectangular handle can be grabbed and dragged to
  /// scrub; the lighter track behind shows how much has buffered.
  Widget _buildSeekBar() {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: widget.controller,
      builder: (BuildContext context, VideoPlayerValue value, Widget? child) {
        final double total = value.duration.inMilliseconds / 1000;
        // Guard against a zero-length video: Slider requires max > min.
        if (total <= 0) return const SizedBox(height: 20);

        final double current =
            _dragSeconds ??
            _scrubSeconds ??
            _pendingSeekSeconds ??
            value.position.inMilliseconds / 1000;

        return SliderTheme(
          data: SliderThemeData(
            trackHeight: 3,
            thumbShape: const RectangleThumb(),
            overlayShape: SliderComponentShape.noOverlay,
            trackShape: const RectangularSliderTrackShape(),
            activeTrackColor: Colors.lightBlueAccent,
            secondaryActiveTrackColor: Colors.white38,
            inactiveTrackColor: Colors.white24,
            thumbColor: Colors.white,
          ),
          child: Slider(
            key: const ValueKey<String>('seek-bar'),
            value: current.clamp(0, total),
            max: total,
            secondaryTrackValue: _bufferedSeconds(value).clamp(0, total),
            // Follow the finger without seeking on every pixel of movement.
            onChanged: (double v) => setState(() => _dragSeconds = v),
            onChangeStart: (double v) {
              _hideTimer?.cancel();
              setState(() => _dragSeconds = v);
            },
            // Seek once, on release, and keep showing the target until
            // playback catches up to it.
            onChangeEnd: (double v) async {
              setState(() {
                _dragSeconds = null;
                _pendingSeekSeconds = v;
              });
              _armSeekRelease(_seekSafetyTimeout);
              await widget.controller.seekTo(
                Duration(milliseconds: (v * 1000).round()),
              );
              if (!mounted) return;
              _revealControls();
              _armSeekRelease(_seekSettleWindow);
            },
          ),
        );
      },
    );
  }

  /// The bar floating over the bottom of the picture: seek bar, play button, time.
  Widget _buildControlBar() {
    return MouseRegion(
      onEnter: (_) => _pointerOnControls = true,
      onExit: (_) => _pointerOnControls = false,
      child: Container(
        // Bottom-up black gradient so white text stays readable over bright frames.
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: <Color>[Color(0xCC000000), Color(0x00000000)],
          ),
        ),
        // Runway for the gradient to fade over. Was 32, which bought a
        // smoother fade at the cost of a third of the bar's height — the
        // gradient still reads at 14 and the bar sits far lower on the video.
        padding: const EdgeInsets.only(top: 14),
        child: Padding(
          // Bottom padding carries the gesture strip so the gradient still
          // reaches the screen edge while the row sits above it.
          padding: EdgeInsets.fromLTRB(4, 2, 8, 2 + _gestureInset),
          // One row, the way Bilibili does it: play, track, clock, then the
          // right-hand buttons. Stacking the track above the row read fine on
          // a desktop window but cost a whole row of height, and in a 16:9
          // phone slot that is video the bar is sitting on.
          child: Row(
            children: <Widget>[
              // The position changes every frame. ValueListenableBuilder
              // rebuilds only the icon and the clock rather than the page.
              ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: widget.controller,
                builder:
                    (
                      BuildContext context,
                      VideoPlayerValue value,
                      Widget? child,
                    ) => IconButton(
                      key: const ValueKey<String>('play-pause-button'),
                      onPressed: _togglePlay,
                      color: Colors.white,
                      iconSize: 20,
                      // An IconButton takes its 48x48 tap target from the
                      // theme, so neither `constraints` nor a compact
                      // visualDensity shrinks it — only tapTargetSize does. 36
                      // is under Material's recommended minimum: a deliberate
                      // trade for the compact bar, and a mild one here because
                      // the picture behind takes a double tap for the same
                      // action.
                      style: IconButton.styleFrom(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        minimumSize: const Size(36, 36),
                        padding: EdgeInsets.zero,
                      ),
                      icon: Icon(
                        value.isPlaying ? Icons.pause : Icons.play_arrow,
                      ),
                    ),
              ),
              Expanded(child: _buildSeekBar()),
              ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: widget.controller,
                builder:
                    (
                      BuildContext context,
                      VideoPlayerValue value,
                      Widget? child,
                    ) => Padding(
                      padding: const EdgeInsets.only(left: 8, right: 2),
                      // Bilibili writes the pair with no spaces around the
                      // slash, which is worth copying now that the clock shares
                      // a row with the track. While dragging, show where you
                      // are heading, not where the video still is.
                      child: Text(
                        '${formatDuration(_dragSeconds == null ? value.position : Duration(milliseconds: (_dragSeconds! * 1000).round()))}/'
                        '${formatDuration(value.duration)}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          // Stops the row twitching as the digits change.
                          fontFeatures: <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                    ),
              ),
              if (widget.isFullscreen) ...<Widget>[
                _buildFillButton(),
                ...widget.extraControls,
                _buildSpeedMenu(),
              ],
              if (widget.onToggleFullscreen != null) _buildFullscreenButton(),
            ],
          ),
        ),
      ),
    );
  }

  /// The picture, either letterboxed whole or scaled up to fill the screen.
  ///
  /// TUM-Live's combined stream is a 16:9 frame with the slides and the camera
  /// packed into the top of it — measured on a real lecture, the content stops
  /// about three quarters of the way down and the bottom quarter is black. That
  /// black is *in the video*, not letterboxing, so no amount of fitting the
  /// frame to the screen gets rid of it.
  ///
  /// Filling anchors the crop to the top rather than the centre. A centred
  /// BoxFit.cover would take equal bites out of the top and bottom, and the top
  /// is where the slides and the camera actually are; anchored to the top it
  /// eats the padding instead.
  Widget _buildPicture() {
    if (!_fillScreen) {
      return Center(
        child: AspectRatio(
          aspectRatio: widget.controller.value.aspectRatio,
          child: VideoPlayer(widget.controller),
        ),
      );
    }
    final Size size = widget.controller.value.size;
    if (size.isEmpty) {
      return Center(child: VideoPlayer(widget.controller));
    }
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: VideoPlayer(widget.controller),
        ),
      ),
    );
  }

  /// How much of the picture's width the camera inset takes, and how solid it
  /// is.
  ///
  /// Faint and small on purpose. This is a glance at who is talking, not
  /// something to watch — the slides underneath are what the lecture is, and an
  /// opaque box parked on them would hide the corner of every one.
  /// Narrower in a 16:9 slot than in fullscreen. The same fraction reads as a
  /// small corner on a full screen and as a third of the picture in a phone's
  /// 16:9 box, where the slides have far less room to spare.
  static const double _overlayWidthFullscreen = 0.22;
  static const double _overlayWidthWindowed = 0.15;
  static const double _overlayMinWidth = 60;
  static const double _overlayMaxWidth = 220;
  static const double _overlayOpacity = 0.6;

  /// Roughly the control bar's height, so the default corner clears it.
  /// Add [_gestureInset] for the height the bar actually occupies.
  static const double _controlBarHeight = 54;

  /// How much of the bottom edge belongs to Android's navigation gesture.
  ///
  /// In fullscreen the chrome fills the display, so controls pinned to
  /// `bottom: 0` land in the strip where a vertical drag means "go home". The
  /// system claims that drag before the Slider ever sees it, so scrubbing from
  /// near the bottom edge backgrounds the app instead of seeking.
  ///
  /// `SafeArea` does not fix it: fullscreen runs under `immersiveSticky`, which
  /// hides the navigation bar and drops `viewPadding` to zero while the gesture
  /// keeps firing. `systemGestureInsets` is the only inset that still reports
  /// the strip once the bar is hidden.
  ///
  /// Zero when windowed, where the picture is a 16:9 slot with the lecture list
  /// underneath and the bar is nowhere near the screen edge.
  double get _gestureInset => widget.isFullscreen
      ? MediaQuery.of(context).systemGestureInsets.bottom
      : 0;

  /// Where the user has dragged the inset to, or null while it is still
  /// wherever the player put it.
  CameraInset? _inset;
  final CameraInsetPreference _insetPreference = const CameraInsetPreference();

  /// The corner a drag took hold of, or null when the drag is moving the inset.
  _Corner? _grabbedCorner;

  /// How small and large a dragged inset may get, as a fraction of the picture.
  static const double _insetMinFraction = 0.08;
  static const double _insetMaxFraction = 0.5;

  /// How far the inset's touch area reaches beyond the picture it draws.
  ///
  /// Growing the corner zones inwards instead would have eaten the middle,
  /// which is what drags the inset around — on a small inset there is barely a
  /// middle to begin with. Reaching outwards costs nothing: the surrounding
  /// pixels are slides, and a drag that starts on them was meant for the inset
  /// anyway.
  static const double _insetTouchPadding = 12;

  /// The largest a corner grab zone gets, before the inset's own size caps it.
  static const double _insetGrabMax = 36;

  /// Where the picture actually lands inside a [boxW] x [boxH] player.
  ///
  /// The video keeps its aspect ratio, so on a wide screen a 16:9 lecture is
  /// pillarboxed and the player's own right edge is black. The inset belongs to
  /// the slides, not to that black, so it is positioned against this.
  Rect _pictureRect(double boxW, double boxH) {
    final double ratio = widget.controller.value.aspectRatio;
    if (_fillScreen || ratio <= 0) return Rect.fromLTWH(0, 0, boxW, boxH);
    double w = boxW;
    double h = boxW / ratio;
    if (h > boxH) {
      h = boxH;
      w = boxH * ratio;
    }
    return Rect.fromLTWH((boxW - w) / 2, (boxH - h) / 2, w, h);
  }

  /// Where the inset sits when the user has never moved it: tucked into the
  /// bottom-right of the slides, clear of the control bar.
  CameraInset _defaultInset(Rect picture, double boxH) {
    const double margin = 10;
    final double fraction = widget.isFullscreen
        ? _overlayWidthFullscreen
        : _overlayWidthWindowed;
    final double width = (picture.width * fraction).clamp(
      _overlayMinWidth,
      _overlayMaxWidth,
    );
    final double belowPicture = boxH - picture.bottom;
    // Measured up from the picture's own bottom edge, so it means the same
    // thing whether or not the picture is letterboxed.
    final double bottom =
        math.max(
          belowPicture + margin,
          _controlBarHeight + _gestureInset + margin,
        ) -
        belowPicture;
    return CameraInset(
      right: margin / picture.width,
      bottom: bottom / picture.height,
      width: width / picture.width,
    );
  }

  /// The inset in pixels, kept whole and inside the picture.
  ///
  /// Clamping lives here rather than in the drag handlers because the stored
  /// fractions come from whatever screen the user last dragged on: a corner
  /// that was comfortably inside a full landscape picture can fall outside a
  /// 16:9 slot, and an inset parked off-screen cannot be dragged back.
  Rect _insetRect(Rect picture, double boxH) {
    final CameraInset inset = _inset ?? _defaultInset(picture, boxH);
    final double width = (inset.width * picture.width).clamp(
      _insetMinFraction * picture.width,
      _insetMaxFraction * picture.width,
    );
    final double height = width / widget.overlayAspectRatio;
    final double right = (inset.right * picture.width).clamp(
      0,
      math.max(0, picture.width - width),
    );
    final double bottom = (inset.bottom * picture.height).clamp(
      0,
      math.max(0, picture.height - height),
    );
    return Rect.fromLTWH(
      picture.right - right - width,
      picture.bottom - bottom - height,
      width,
      height,
    );
  }

  void _storeInset(Rect picture, Rect rect) {
    final CameraInset inset = CameraInset(
      right: (picture.right - rect.right) / picture.width,
      bottom: (picture.bottom - rect.bottom) / picture.height,
      width: rect.width / picture.width,
    );
    setState(() => _inset = inset);
    unawaited(_insetPreference.write(inset));
  }

  /// The camera, draggable around the slides and resizable from any corner.
  ///
  /// One gesture detector, not five. Nesting a detector per corner inside the
  /// one that moves the inset put two pan recognizers in the same arena for
  /// every drag, and they cancelled each other out — nothing moved at all.
  /// Where the finger lands decides what the drag means instead.
  ///
  /// The corners have nothing drawn in them. An inset this small is mostly
  /// corner, and a visible handle would be a badge sitting on the lecturer's
  /// face for the whole lecture to say what the shape already implies.
  Widget _buildOverlay(double boxW, double boxH) {
    final Rect picture = _pictureRect(boxW, boxH);
    if (picture.isEmpty) return const SizedBox.shrink();
    final Rect rect = _insetRect(picture, boxH);

    final Rect touch = rect.inflate(_insetTouchPadding);

    return Positioned(
      left: touch.left,
      top: touch.top,
      width: touch.width,
      height: touch.height,
      child: GestureDetector(
        key: const ValueKey<String>('camera-inset'),
        behavior: HitTestBehavior.opaque,
        onPanStart: (DragStartDetails details) {
          _grabbedCorner = _cornerAt(details.localPosition, touch.size);
        },
        onPanUpdate: (DragUpdateDetails details) {
          final _Corner? corner = _grabbedCorner;
          if (corner == null) {
            _dragInset(picture, boxH, details.delta);
          } else {
            _resizeInset(corner, picture, boxH, details.delta);
          }
        },
        onPanEnd: (_) {
          _grabbedCorner = null;
          _revealControls();
        },
        child: Padding(
          padding: const EdgeInsets.all(_insetTouchPadding),
          child: Opacity(
            opacity: _overlayOpacity,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: widget.overlay,
            ),
          ),
        ),
      ),
    );
  }

  /// Which corner [local] falls in, or null for the middle — which moves it.
  ///
  /// The zones are a third of the inset rather than a fixed size: four fixed
  /// corners would cover a small inset completely, leaving nothing to drag it
  /// by.
  _Corner? _cornerAt(Offset local, Size size) {
    final double grabW = math.min(_insetGrabMax, size.width / 3);
    final double grabH = math.min(_insetGrabMax, size.height / 3);
    final bool left = local.dx <= grabW;
    final bool right = local.dx >= size.width - grabW;
    final bool top = local.dy <= grabH;
    final bool bottom = local.dy >= size.height - grabH;
    if (top && left) return _Corner.topLeft;
    if (top && right) return _Corner.topRight;
    if (bottom && left) return _Corner.bottomLeft;
    if (bottom && right) return _Corner.bottomRight;
    return null;
  }

  void _dragInset(Rect picture, double boxH, Offset delta) {
    final Rect rect = _insetRect(picture, boxH).shift(delta);
    // Kept whole inside the picture rather than merely overlapping it.
    final double left = rect.left.clamp(
      picture.left,
      math.max(picture.left, picture.right - rect.width),
    );
    final double top = rect.top.clamp(
      picture.top,
      math.max(picture.top, picture.bottom - rect.height),
    );
    _storeInset(picture, Rect.fromLTWH(left, top, rect.width, rect.height));
  }

  /// Resizes by dragging [corner], with the opposite corner pinned.
  ///
  /// Pinning the far corner is what makes a resize feel like stretching rather
  /// than sliding: the edge under the finger follows it and nothing else moves.
  void _resizeInset(_Corner corner, Rect picture, double boxH, Offset delta) {
    final Rect rect = _insetRect(picture, boxH);
    // Dragging a left corner leftwards grows it; a right corner does the
    // opposite. Width alone drives the shape — the aspect ratio gives height.
    final double proposed = corner.onLeft
        ? rect.width - delta.dx
        : rect.width + delta.dx;

    // How far the pinned corner leaves us before running out of picture.
    final double roomX = corner.onLeft
        ? rect.right - picture.left
        : picture.right - rect.left;
    final double roomY = corner.onTop
        ? rect.bottom - picture.top
        : picture.bottom - rect.top;

    final double width = proposed.clamp(
      _insetMinFraction * picture.width,
      math.min(
        _insetMaxFraction * picture.width,
        math.min(roomX, roomY * widget.overlayAspectRatio),
      ),
    );
    final double height = width / widget.overlayAspectRatio;

    _storeInset(
      picture,
      Rect.fromLTWH(
        corner.onLeft ? rect.right - width : rect.left,
        corner.onTop ? rect.bottom - height : rect.top,
        width,
        height,
      ),
    );
  }

  Widget _buildFillButton() {
    return IconButton(
      key: const ValueKey<String>('fill-screen-button'),
      tooltip: _fillScreen ? 'Fit whole frame' : 'Fill screen',
      onPressed: () {
        setState(() => _fillScreen = !_fillScreen);
        _revealControls();
      },
      color: Colors.white,
      iconSize: 20,
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize: const Size(36, 36),
        padding: EdgeInsets.zero,
      ),
      icon: Icon(
        _fillScreen ? Icons.close_fullscreen_rounded : Icons.crop_free_rounded,
      ),
    );
  }

  Widget _buildFullscreenButton() {
    return IconButton(
      key: const ValueKey<String>('fullscreen-button'),
      tooltip: widget.isFullscreen ? 'Exit fullscreen' : 'Fullscreen',
      onPressed: () {
        widget.onToggleFullscreen!();
        _revealControls();
      },
      color: Colors.white,
      iconSize: 20,
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize: const Size(36, 36),
        padding: EdgeInsets.zero,
      ),
      icon: Icon(
        widget.isFullscreen
            ? Icons.fullscreen_exit_rounded
            : Icons.fullscreen_rounded,
      ),
    );
  }

  /// Where a horizontal swipe is heading: target time, total, and the signed
  /// offset from where the swipe began.
  Widget _buildScrubIndicator() {
    final double? target = _scrubSeconds;
    if (target == null) return const SizedBox.shrink();
    final Duration total = widget.controller.value.duration;
    final int delta = (target - (_scrubOriginSeconds ?? target)).round();
    return IgnorePointer(
      child: Center(
        child: Container(
          key: const ValueKey<String>('scrub-indicator'),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xB3000000),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text.rich(
                TextSpan(
                  children: <InlineSpan>[
                    TextSpan(
                      text: formatDuration(
                        Duration(milliseconds: (target * 1000).round()),
                      ),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    TextSpan(
                      text: ' / ${formatDuration(total)}',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 2),
              Text(
                delta >= 0 ? '+${delta}s' : '${delta}s',
                style: const TextStyle(
                  color: Colors.lightBlueAccent,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color(0xB3000000), Color(0x00000000)],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(4, 4, 12, 24),
      child: Row(
        children: <Widget>[
          if (widget.onBack != null)
            IconButton(
              key: const ValueKey<String>('player-back-button'),
              // What back *does* is the page's call, but only the chrome knows
              // enough to label it: in fullscreen the host wires it to leave
              // fullscreen rather than the lecture.
              tooltip: widget.isFullscreen ? 'Exit fullscreen' : 'Back',
              onPressed: widget.onBack,
              color: Colors.white,
              iconSize: 22,
              icon: const Icon(Icons.arrow_back),
            )
          else
            const SizedBox(width: 12),
          if (widget.title != null)
            Expanded(
              child: Text(
                widget.title!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSpeedMenu() {
    return Builder(
      builder: (BuildContext context) => Tooltip(
        message: 'Playback speed',
        child: InkWell(
          key: const ValueKey<String>('speed-menu'),
          onTap: () async {
            final double? picked = await showBarMenu<double>(
              context: context,
              initialValue: _speed,
              items: <PopupMenuEntry<double>>[
                for (final double speed in _speeds)
                  PopupMenuItem<double>(
                    value: speed,
                    height: popupMenuItemHeight,
                    child: Text(
                      speed == 1.0 ? 'Normal' : '${speed}x',
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ),
              ],
            );
            if (picked != null) await _setSpeed(picked);
            _revealControls();
          },
          child: SizedBox(
            width: popupMenuButtonWidth,
            height: popupMenuButtonHeight,
            child: Center(
              child: Text(
                _speed == 1.0 ? '1x' : '${_speed}x',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // LayoutBuilder hands us the player's real height, which is what decides
    // where the bottom strip starts.
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double height = constraints.maxHeight;
        final double width = constraints.maxWidth;
        return MouseRegion(
          key: const ValueKey<String>('player-surface'),
          onEnter: (PointerEnterEvent event) =>
              _handlePointer(event.localPosition, height),
          onHover: (PointerHoverEvent event) =>
              _handlePointer(event.localPosition, height),
          onExit: (_) {
            _pointerOnControls = false;
            _maybeHideControls();
          },
          // Hide the cursor along with the bar, like Bilibili does in fullscreen.
          cursor: _controlsVisible
              ? SystemMouseCursors.basic
              : SystemMouseCursors.none,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              // The picture keeps its aspect ratio, centred; the Stack
              // itself fills the window so the bottom strip is the window's
              // bottom, not the letterboxed picture's.
              _buildPicture(),
              // The gesture surface sits *under* the chrome rather than
              // wrapping it, so a tap that lands on a control is absorbed by
              // that control and never reaches here — pressing play should not
              // also toggle the overlay. Wrapping the chrome instead also
              // starves descendant buttons whenever the parent claims a
              // gesture, which is how the play button once stopped responding
              // altogether.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // One recognizer for both taps. See [_awaitingSecondTap] for
                  // why onDoubleTap is not used.
                  onTapUp: _handleTapUp,
                  // Swipe sideways anywhere on the picture to scrub. A swipe
                  // starting on the seek bar belongs to the bar, which is
                  // above this layer and takes the hit first.
                  onHorizontalDragStart: (_) => _handleScrubStart(),
                  onHorizontalDragUpdate: (DragUpdateDetails details) =>
                      _handleScrubUpdate(details, width),
                  onHorizontalDragEnd: (_) => _handleScrubEnd(),
                ),
              ),
              // Feedback sits above the picture but below the bars, so a
              // scrub readout never fights the control bar for the middle of
              // the screen.
              // Above the gesture surface, so drags on it move the inset
              // rather than scrubbing the lecture underneath.
              if (widget.overlay != null) _buildOverlay(width, height),
              Positioned.fill(child: _buildScrubIndicator()),
              // Back and title float over the picture rather than sitting in
              // an app bar above it. On a phone that bar costs ~56dp of
              // vertical space permanently, which the video needs more.
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: AnimatedOpacity(
                  key: const ValueKey<String>('top-bar'),
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: _buildTopBar(),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: AnimatedOpacity(
                  key: const ValueKey<String>('control-bar'),
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  // Once faded out the bar must not swallow clicks.
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: _buildControlBar(),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Which corner of the camera inset a drag has hold of.
enum _Corner {
  topLeft(onLeft: true, onTop: true),
  topRight(onLeft: false, onTop: true),
  bottomLeft(onLeft: true, onTop: false),
  bottomRight(onLeft: false, onTop: false);

  const _Corner({required this.onLeft, required this.onTop});

  final bool onLeft;
  final bool onTop;
}
