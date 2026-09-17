/// Owns a [VideoPlayerController] for one URL: loading, failure, retry.
///
/// Knows nothing about TUM-Live. Hand it an HLS URL and it plays it, which is
/// what makes it testable without a network or a fake API — the widget tests
/// drive it through a fake `VideoPlayerPlatform`.
///
/// Resolving a lecture id into a (short-lived, signed) URL is [PlayerPage]'s
/// job, one layer up.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'player_controls.dart';

class LecturePlayer extends StatefulWidget {
  const LecturePlayer({
    super.key,
    required this.videoUrl,
    this.overlayVideoUrl,
    required this.title,
    this.subtitle,
    this.extraControls = const <Widget>[],
    this.onBack,
    this.startAt,
    this.onPositionChanged,
    this.onRetry,
    this.isFullscreen = false,
    this.onToggleFullscreen,
    this.onPlayingChanged,
  });

  /// An HLS playlist URL, usually carrying a `?jwt=` that expires in ~7 hours.
  final String videoUrl;

  /// A second stream to play over the first, bottom-right — the camera in
  /// `LectureSource.fused`. Null for every ordinary source.
  ///
  /// It is a whole second decode, so this is opt-in rather than something the
  /// player does whenever a camera track happens to exist.
  final String? overlayVideoUrl;

  final String title;
  final String? subtitle;

  /// Shown on the back button overlaid on the video. Null hides it.
  final VoidCallback? onBack;

  /// Extra buttons for the control bar, e.g. the camera-angle switcher.
  final List<Widget> extraControls;

  /// Where to resume from, once the video reports it is ready.
  final Duration? startAt;

  final void Function(Duration position, Duration duration)? onPositionChanged;

  /// Fired when playback starts or stops. See [PlayerChrome.onPlayingChanged].
  final ValueChanged<bool>? onPlayingChanged;

  /// Whether the picture has the whole screen. Passed straight to
  /// [PlayerChrome], which uses it to decide how much belongs in the bar.
  final bool isFullscreen;

  /// Enters or leaves fullscreen. Null hides the button.
  final VoidCallback? onToggleFullscreen;

  /// What the Retry button should do.
  ///
  /// When null, Retry just rebuilds the controller with the same URL. Pass a
  /// callback to re-resolve the lecture first — which is what you want in the
  /// real app, because the usual reason playback fails is an expired token.
  final VoidCallback? onRetry;

  @override
  State<LecturePlayer> createState() => _LecturePlayerState();
}

class _LecturePlayerState extends State<LecturePlayer> {
  late VideoPlayerController _controller;
  bool _isError = false;

  /// The camera track drawn over the picture, when the fused source is on.
  VideoPlayerController? _overlay;
  bool _overlayReady = false;
  Timer? _syncTimer;

  /// How often to check the two streams against each other. They are separate
  /// decoders with separate clocks, so they drift; nothing keeps them together
  /// except this.
  static const Duration _syncInterval = Duration(seconds: 2);

  /// How far apart they may drift before the camera is nudged back. Below
  /// roughly this, a re-seek is more distracting than the drift.
  static const Duration _maxDrift = Duration(milliseconds: 400);

  /// Set once we have seeked to [LecturePlayer.startAt], so a later rebuild
  /// cannot yank the user back to where they started.
  bool _resumed = false;

  @override
  void initState() {
    super.initState();
    _load();
    _loadOverlay();
  }

  @override
  void didUpdateWidget(LecturePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new URL means a different source (or a freshly signed token for the
    // same one). Either way the old controller is useless.
    if (oldWidget.videoUrl != widget.videoUrl) {
      final VideoPlayerController old = _controller;
      setState(() {
        _resumed = false;
        _load();
      });
      if (!_isError) old.dispose();
    }
    if (oldWidget.overlayVideoUrl != widget.overlayVideoUrl) {
      _disposeOverlay();
      _loadOverlay();
    }
  }

  /// Boots the camera track and starts keeping it in step with the picture.
  void _loadOverlay() {
    final String? url = widget.overlayVideoUrl;
    if (url == null) return;
    final VideoPlayerController overlay = VideoPlayerController.networkUrl(
      Uri.parse(url),
      // Without this the two streams stall each other dead. Both players ask
      // the platform for exclusive audio focus, so each one starting takes it
      // from the other, and media3 pauses on a permanent focus loss — on a real
      // device both decoders sat at inputFps=0 while the log filled with
      // onAudioFocusChange(-1). Muting is not the same as declining focus:
      // mixWithOthers is what stops the request being made at all. The main
      // stream keeps focus, so other apps still yield to a lecture.
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    _overlay = overlay;
    overlay
        .initialize()
        .then((_) {
          if (!mounted || _overlay != overlay) return;
          // One soundtrack between them, and it belongs to the main stream.
          overlay.setVolume(0);
          setState(() => _overlayReady = true);
          _controller.addListener(_followMain);
          _syncTimer = Timer.periodic(
            _syncInterval,
            (_) => unawaited(_correctDrift()),
          );
          unawaited(_correctDrift(force: true));
        })
        .catchError((Object error) {
          // The camera is a bonus layer. Losing it leaves the lecture playing.
          debugPrint('Fused overlay failed to load: $error');
          if (!mounted) return;
          setState(() => _overlayReady = false);
        });
  }

  void _disposeOverlay() {
    _syncTimer?.cancel();
    _syncTimer = null;
    _controller.removeListener(_followMain);
    _overlay?.dispose();
    _overlay = null;
    _overlayReady = false;
  }

  /// Play, pause and speed, matched the moment the main stream changes.
  ///
  /// Position is deliberately not handled here — this runs on every frame the
  /// main controller reports, and seeking that often would stutter both. Drift
  /// is [_correctDrift]'s job, on a timer.
  void _followMain() {
    final VideoPlayerController? overlay = _overlay;
    if (overlay == null || !_overlayReady) return;
    final VideoPlayerValue main = _controller.value;
    if (!main.isInitialized) return;
    if (main.isPlaying != overlay.value.isPlaying) {
      main.isPlaying ? overlay.play() : overlay.pause();
    }
    if (main.playbackSpeed != overlay.value.playbackSpeed) {
      unawaited(overlay.setPlaybackSpeed(main.playbackSpeed));
    }
  }

  Future<void> _correctDrift({bool force = false}) async {
    final VideoPlayerController? overlay = _overlay;
    if (overlay == null || !_overlayReady || !mounted) return;
    final VideoPlayerValue main = _controller.value;
    if (!main.isInitialized) return;
    final Duration drift = main.position - overlay.value.position;
    if (!force && drift.abs() <= _maxDrift) return;
    await overlay.seekTo(main.position);
  }

  /// Creates a fresh controller and starts loading the stream.
  void _load() {
    _isError = false;
    _controller = VideoPlayerController.networkUrl(
      Uri.parse(widget.videoUrl),
      // Stated rather than left to the default, because the platform reads this
      // as one global flag at creation time, not per player: whatever the last
      // controller asked for is what the next one gets. The overlay sets it to
      // true, so without this a later reload of the main stream would silently
      // inherit that and stop taking audio focus from other apps.
      videoPlayerOptions: VideoPlayerOptions(),
    );
    _controller
        .initialize()
        .then((_) {
          // initialize() may finish after the widget is gone; setState would throw.
          if (!mounted) return;
          // Loaded: rebuild so the player shows, then start playing.
          setState(() {});
          _maybeResume();
          _controller.play();
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

  /// Jumps to the stored watch position, if there is a useful one.
  void _maybeResume() {
    final Duration? start = widget.startAt;
    if (_resumed || start == null || start <= Duration.zero) return;
    final Duration duration = _controller.value.duration;
    // Never resume within the last 30 seconds: the user finished it, and
    // dropping them at the credits is worse than starting over.
    if (duration > Duration.zero &&
        start >= duration - const Duration(seconds: 30)) {
      _resumed = true;
      return;
    }
    _resumed = true;
    _controller.seekTo(start);
  }

  /// Reloads the video. Delegates to [LecturePlayer.onRetry] when the owner
  /// wants to re-resolve the URL first.
  void _retry() {
    if (widget.onRetry != null) {
      widget.onRetry!();
      return;
    }
    // Calling dispose() on a controller whose initialize() failed hangs forever:
    // video_player only completes its internal _creatingCompleter on the success
    // path, but dispose() always awaits it. So we just drop the old controller.
    setState(_load);
  }

  @override
  void dispose() {
    _disposeOverlay();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Just the picture, filling whatever box the parent gives it. Sizing is the
    // host page's job — a 16:9 slot in portrait, the whole screen in landscape —
    // so the player itself stays layout-agnostic and easy to test.
    final bool hasChrome = !_isError && _controller.value.isInitialized;
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        children: <Widget>[
          Positioned.fill(child: Center(child: _buildBody())),
          // While the video is playing, the back button rides in the chrome's
          // fading top bar. Loading and failure states have no chrome, so
          // without this there is no way out of a lecture that will not load.
          if (!hasChrome && widget.onBack != null)
            Positioned(
              top: 0,
              left: 0,
              child: SafeArea(
                child: IconButton(
                  key: const ValueKey<String>('player-back-button'),
                  onPressed: widget.onBack,
                  color: Colors.white,
                  iconSize: 22,
                  icon: const Icon(Icons.arrow_back),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isError) {
      // Sized for a 16:9 slot on a phone, which is about 225dp tall — not the
      // full screen this once assumed. Scrollable and compact so it cannot
      // overflow whatever box the page gives it.
      return SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text(
              'Could not load the video.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 15),
            ),
            const SizedBox(height: 4),
            const Text(
              'The signed link may have expired, or the network is '
              'unavailable.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              key: const ValueKey<String>('retry-button'),
              onPressed: _retry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry'),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ),
      );
    }
    if (!_controller.value.isInitialized) {
      return const CircularProgressIndicator(color: Colors.white);
    }
    return PlayerChrome(
      controller: _controller,
      overlay: _overlayReady && _overlay != null
          ? VideoPlayer(_overlay!)
          : null,
      // The chrome sizes and positions the inset, so it needs the shape; the
      // child no longer decides it.
      overlayAspectRatio: _overlay?.value.aspectRatio ?? 16 / 9,
      onPositionChanged: widget.onPositionChanged,
      extraControls: widget.extraControls,
      title: widget.title,
      onBack: widget.onBack,
      isFullscreen: widget.isFullscreen,
      onToggleFullscreen: widget.onToggleFullscreen,
      onPlayingChanged: widget.onPlayingChanged,
    );
  }
}
