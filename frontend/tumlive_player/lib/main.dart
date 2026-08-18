import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

const videoLink =
    'https://edge.live.rbg.tum.de/REDACTED/playlist.m3u8';

void main() => runApp(const TumLiveApp());

/// Root widget of the app. Tests reuse this too, so they exercise the real
/// widget tree instead of a rebuilt approximation.
class TumLiveApp extends StatelessWidget {
  const TumLiveApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: TUMLivePlayerTest(),
  );
}

/// A small rounded rectangle used as the seek handle, instead of Material's
/// default circle. Painted by the Slider at the current position.
class _RectangleThumb extends SliderComponentShape {
  const _RectangleThumb();

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

class TUMLivePlayerTest extends StatefulWidget {
  const TUMLivePlayerTest({super.key});

  @override
  State<TUMLivePlayerTest> createState() => _TUMLivePlayerTestState();
}

class _TUMLivePlayerTestState extends State<TUMLivePlayerTest> {
  late VideoPlayerController _controller;
  bool _isError = false;

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

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Creates a fresh controller and starts loading the stream.
  ///
  /// Note: initState runs once per State object. Hot reload (r) does NOT re-run
  /// it, so after pasting a new jwt you need a hot restart (R) or the on-screen
  /// Retry button.
  void _load() {
    _isError = false;
    _pendingSeekSeconds = null;
    _seekSettleTimer?.cancel();
    _controller = VideoPlayerController.networkUrl(Uri.parse(videoLink));
    _controller
        .initialize()
        .then((_) {
          // initialize() may finish after the widget is gone; setState would throw.
          if (!mounted) return;
          // Loaded: rebuild so the player shows, then start playing.
          setState(() {});
          _controller.play();
          // Flash the bar once, then start the hide countdown. Without this the bar
          // would stay up forever until the first mouse event.
          _revealControls();
        })
        .catchError((Object error) {
          // Network failure, expired token, or a sandbox permission problem.
          if (!mounted) return;
          setState(() {
            _isError = true;
          });
          debugPrint('Failed to load video: $error');
        });
  }

  /// Reloads using the current videoLink. After hot-reloading a new jwt you can
  /// just tap this instead of restarting the whole app.
  void _retry() {
    // Calling dispose() on a controller whose initialize() failed hangs forever:
    // video_player only completes its internal _creatingCompleter on the success
    // path, but dispose() always awaits it. So we just drop the old controller.
    setState(_load);
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _seekSettleTimer?.cancel();
    _controller.dispose();
    super.dispose();
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
    if (_pointerOnControls || !_controller.value.isPlaying) return;
    setState(() => _controlsVisible = false);
  }

  /// True when [localY] falls in the bottom strip of a player [height] tall.
  bool _inHotZone(double localY, double height) {
    final zone = math.max(_hotZoneMinHeight, height * _hotZoneFraction);
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
    _controller.value.isPlaying ? _controller.pause() : _controller.play();
    _revealControls();
  }

  // Formats a Duration as mm:ss, or h:mm:ss once it passes an hour.
  String _formatDuration(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final minutes = two(d.inMinutes.remainder(60));
    final seconds = two(d.inSeconds.remainder(60));
    return d.inHours > 0
        ? '${d.inHours}:$minutes:$seconds'
        : '$minutes:$seconds';
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
      valueListenable: _controller,
      builder: (context, value, child) {
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
            thumbShape: const _RectangleThumb(),
            overlayShape: SliderComponentShape.noOverlay,
            trackShape: const RectangularSliderTrackShape(),
            activeTrackColor: Colors.lightBlueAccent,
            secondaryActiveTrackColor: Colors.white38,
            inactiveTrackColor: Colors.white24,
            thumbColor: Colors.white,
          ),
          child: Slider(
            key: const ValueKey('seek-bar'),
            value: current.clamp(0, total),
            max: total,
            secondaryTrackValue: _bufferedSeconds(value).clamp(0, total),
            // Follow the finger without seeking on every pixel of movement.
            onChanged: (v) => setState(() => _dragSeconds = v),
            onChangeStart: (v) {
              _hideTimer?.cancel();
              setState(() => _dragSeconds = v);
            },
            // Seek once, on release, and keep showing the target until
            // playback catches up to it.
            onChangeEnd: (v) async {
              setState(() {
                _dragSeconds = null;
                _pendingSeekSeconds = v;
              });
              _armSeekRelease(_seekSafetyTimeout);
              await _controller.seekTo(
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
            colors: [Color(0xCC000000), Color(0x00000000)],
          ),
        ),
        padding: const EdgeInsets.only(top: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildSeekBar(),
            // The position changes every frame. ValueListenableBuilder rebuilds
            // only this row instead of calling setState on the whole page.
            ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: _controller,
              builder: (context, value, child) => Row(
                children: [
                  IconButton(
                    key: const ValueKey('play-pause-button'),
                    onPressed: _togglePlay,
                    color: Colors.white,
                    iconSize: 22,
                    icon: Icon(
                      value.isPlaying ? Icons.pause : Icons.play_arrow,
                    ),
                  ),
                  // Bilibili shows position and duration together as one label.
                  // While dragging, show where you are heading, not where the
                  // video still is.
                  Text(
                    '${_formatDuration(_dragSeconds == null ? value.position : Duration(milliseconds: (_dragSeconds! * 1000).round()))} / '
                    '${_formatDuration(value.duration)}',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                  const Spacer(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Picture plus floating controls. Any pointer movement summons the bar; it
  /// retreats after three idle seconds.
  Widget _buildPlayer() {
    // LayoutBuilder hands us the player's real height, which is what decides
    // where the bottom strip starts.
    return LayoutBuilder(
      builder: (context, constraints) {
        final double height = constraints.maxHeight;
        return MouseRegion(
          key: const ValueKey('player-surface'),
          onEnter: (event) => _handlePointer(event.localPosition, height),
          onHover: (event) => _handlePointer(event.localPosition, height),
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
              children: [
                // The picture keeps its aspect ratio, centred; the Stack
                // itself fills the window so the bottom strip is the window's
                // bottom, not the letterboxed picture's.
                Center(
                  child: AspectRatio(
                    aspectRatio: _controller.value.aspectRatio,
                    child: VideoPlayer(_controller),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: AnimatedOpacity(
                    key: const ValueKey('control-bar'),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('TUMLive Player'),
        backgroundColor: Colors.blueGrey[900],
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: _isError
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Could not load the video. Check the network '
                    'permission and whether the token is still valid.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.red, fontSize: 18),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const ValueKey('retry-button'),
                    onPressed: _retry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ],
              )
            : _controller.value.isInitialized
            ? _buildPlayer()
            : const CircularProgressIndicator(color: Colors.white), // loading
      ),
    );
  }
}
