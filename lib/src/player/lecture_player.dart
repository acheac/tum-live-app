/// Owns a [VideoPlayerController] for one URL: loading, failure, retry.
///
/// Knows nothing about TUM-Live. Hand it an HLS URL and it plays it, which is
/// what makes it testable without a network or a fake API — the widget tests
/// drive it through a fake `VideoPlayerPlatform`.
///
/// Resolving a lecture id into a (short-lived, signed) URL is [PlayerPage]'s
/// job, one layer up.
library;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'player_controls.dart';

class LecturePlayer extends StatefulWidget {
  const LecturePlayer({
    super.key,
    required this.videoUrl,
    required this.title,
    this.subtitle,
    this.appBarActions = const <Widget>[],
    this.extraControls = const <Widget>[],
    this.startAt,
    this.onPositionChanged,
    this.onRetry,
  });

  /// An HLS playlist URL, usually carrying a `?jwt=` that expires in ~7 hours.
  final String videoUrl;

  final String title;
  final String? subtitle;
  final List<Widget> appBarActions;

  /// Extra buttons for the control bar, e.g. the camera-angle switcher.
  final List<Widget> extraControls;

  /// Where to resume from, once the video reports it is ready.
  final Duration? startAt;

  final void Function(Duration position, Duration duration)? onPositionChanged;

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

  /// Set once we have seeked to [LecturePlayer.startAt], so a later rebuild
  /// cannot yank the user back to where they started.
  bool _resumed = false;

  @override
  void initState() {
    super.initState();
    _load();
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
  }

  /// Creates a fresh controller and starts loading the stream.
  void _load() {
    _isError = false;
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl));
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
    if (duration > Duration.zero && start >= duration - const Duration(seconds: 30)) {
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
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(widget.title, overflow: TextOverflow.ellipsis),
            if (widget.subtitle != null)
              Text(
                widget.subtitle!,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
          ],
        ),
        backgroundColor: Colors.blueGrey[900],
        foregroundColor: Colors.white,
        actions: widget.appBarActions,
      ),
      body: Center(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_isError) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text(
              'Could not load the video. The signed link may have expired, '
              'or the network is unavailable.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.red, fontSize: 18),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const ValueKey<String>('retry-button'),
              onPressed: _retry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
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
      onPositionChanged: widget.onPositionChanged,
      extraControls: widget.extraControls,
    );
  }
}
