/// The chrome that floats over the picture: seek bar, play button, clock.
///
/// Split out from [LecturePlayer] because the two have genuinely different
/// jobs. This file knows nothing about loading a video or about the network —
/// hand it an initialised [VideoPlayerController] and it draws controls for it.
///
/// The behaviour follows Bilibili's player: the bar only wakes up when the
/// pointer is near the bottom of the picture, and it stays up while you are
/// paused or actually touching it.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../common/formatting.dart';

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
  });

  final VideoPlayerController controller;

  /// Fired on every position update while playing. The player page uses this to
  /// report watch progress; throttling is the listener's job, not ours.
  final void Function(Duration position, Duration duration)? onPositionChanged;

  /// Extra buttons for the right-hand side of the control bar, e.g. the
  /// camera-angle switcher.
  final List<Widget> extraControls;

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
    super.dispose();
  }

  void _handleControllerUpdate() {
    final VideoPlayerValue value = widget.controller.value;
    if (!value.isInitialized) return;
    widget.onPositionChanged?.call(value.position, value.duration);
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

  void _togglePlay() {
    widget.controller.value.isPlaying
        ? widget.controller.pause()
        : widget.controller.play();
    _revealControls();
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
            _pendingSeekSeconds ??
            value.position.inMilliseconds / 1000;

        return SliderTheme(
          data: SliderThemeData(
            trackHeight: 4,
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
        padding: const EdgeInsets.only(top: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _buildSeekBar(),
            // The position changes every frame. ValueListenableBuilder rebuilds
            // only this row instead of calling setState on the whole page.
            ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: widget.controller,
              builder:
                  (BuildContext context, VideoPlayerValue value, Widget? child) =>
                      Row(
                        children: <Widget>[
                          IconButton(
                            key: const ValueKey<String>('play-pause-button'),
                            onPressed: _togglePlay,
                            color: Colors.white,
                            iconSize: 22,
                            icon: Icon(
                              value.isPlaying ? Icons.pause : Icons.play_arrow,
                            ),
                          ),
                          // Bilibili shows position and duration together as one
                          // label. While dragging, show where you are heading,
                          // not where the video still is.
                          Text(
                            '${formatDuration(_dragSeconds == null ? value.position : Duration(milliseconds: (_dragSeconds! * 1000).round()))} / '
                            '${formatDuration(value.duration)}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                            ),
                          ),
                          const Spacer(),
                          ...widget.extraControls,
                          _buildSpeedMenu(),
                        ],
                      ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSpeedMenu() {
    return PopupMenuButton<double>(
      key: const ValueKey<String>('speed-menu'),
      tooltip: 'Playback speed',
      initialValue: _speed,
      onSelected: _setSpeed,
      itemBuilder: (BuildContext context) => <PopupMenuEntry<double>>[
        for (final double speed in _speeds)
          PopupMenuItem<double>(
            value: speed,
            child: Text(speed == 1.0 ? 'Normal' : '${speed}x'),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          _speed == 1.0 ? '1x' : '${_speed}x',
          style: const TextStyle(color: Colors.white, fontSize: 13),
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
          child: GestureDetector(
            // Click the picture to toggle playback. Touch devices get no hover
            // events, so this is also how they summon the bar.
            onTap: _togglePlay,
            behavior: HitTestBehavior.opaque,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                // The picture keeps its aspect ratio, centred; the Stack
                // itself fills the window so the bottom strip is the window's
                // bottom, not the letterboxed picture's.
                Center(
                  child: AspectRatio(
                    aspectRatio: widget.controller.value.aspectRatio,
                    child: VideoPlayer(widget.controller),
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
          ),
        );
      },
    );
  }
}
