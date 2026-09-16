/// Turns `(courseSlug, lectureId)` into a playing video.
///
/// This is the layer that exists because **playlist URLs expire**. gocast signs
/// them with a JWT that lives about seven hours, so the app stores lecture ids
/// and resolves a fresh URL immediately before playback. Never the other way
/// round — that is what made the old hardcoded link rot every day.
///
/// It also owns the two things that need the network while you watch: resuming
/// where you left off, and reporting progress back.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_exception.dart';
import '../api/models.dart';
import '../api/tum_live_api.dart';
import '../app_scope.dart';
import '../auth/auth_controller.dart';
import '../common/async_builder.dart';
import 'lecture_player.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.courseSlug,
    required this.lectureId,
    this.courseName,
  });

  final String courseSlug;
  final int lectureId;

  /// Shown in the app bar while the lecture itself is still loading.
  final String? courseName;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

/// Everything the player needs to start, fetched in one go.
class _Playback {
  const _Playback({required this.lecture, required this.course, this.resumeAt});

  final Lecture lecture;
  final Course course;
  final Duration? resumeAt;
}

class _PlayerPageState extends State<PlayerPage> {
  Future<_Playback>? _future;
  LectureSource _source = LectureSource.combined;

  /// Where to start playback. Seeded from the server's stored progress, then
  /// updated locally so switching camera angles does not lose your place.
  Duration? _resumeTarget;

  /// Last position we told the server about, and when.
  DateTime _lastReport = DateTime.fromMillisecondsSinceEpoch(0);
  Duration _lastPosition = Duration.zero;

  /// Reporting on every frame would be thousands of requests per lecture.
  static const Duration _reportInterval = Duration(seconds: 5);

  /// Past this fraction we call the lecture watched.
  static const double _watchedThreshold = 0.9;

  /// Cached so [dispose] can still report a final position after the element
  /// is unmounted, when `context` is no longer safe to read.
  TumLiveApi? _api;
  AuthController? _auth;

  // The first load happens here, not in initState: reading an InheritedWidget
  // registers a dependency, and initState is too early for that. Caching the
  // two objects first means _load() never has to touch `context` at all.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _api = AppScope.apiOf(context);
    _auth = AppScope.authOf(context);
    _future ??= _load();
  }

  @override
  void dispose() {
    // One last report so closing the page mid-lecture still records where you
    // got to. Fire-and-forget: the page is going away either way.
    unawaited(_reportProgress(force: true));
    super.dispose();
  }

  Future<_Playback> _load() async {
    // Set by didChangeDependencies before this can ever run.
    final TumLiveApi api = _api!;
    final AuthController auth = _auth!;

    final CourseLecture result = await api.getLecture(
      widget.courseSlug,
      widget.lectureId,
    );

    Duration? resumeAt;
    if (auth.isSignedIn) {
      try {
        final Map<int, LectureProgress> progress = await api.getProgress(
          <int>[widget.lectureId],
        );
        final LectureProgress? stored = progress[widget.lectureId];
        final Duration total = result.lecture.duration;
        if (stored != null && stored.isStarted && total > Duration.zero) {
          resumeAt = total * stored.progress;
        }
      } on Object {
        // Progress is a nicety. Never let it stop playback.
      }
    }

    _resumeTarget ??= resumeAt;
    return _Playback(
      lecture: result.lecture,
      course: result.course,
      resumeAt: _resumeTarget,
    );
  }

  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  /// Remembers the position and, at most every [_reportInterval], tells the
  /// server about it.
  void _handlePosition(Duration position, Duration duration) {
    _lastPosition = position;
    if (duration <= Duration.zero) return;
    if (DateTime.now().difference(_lastReport) < _reportInterval) return;
    unawaited(_reportProgress(total: duration));
  }

  Future<void> _reportProgress({Duration? total, bool force = false}) async {
    if (!mounted && !force) return;
    final AuthController? auth = _auth;
    if (auth == null || !auth.isSignedIn) return;
    final Duration duration = total ?? Duration.zero;
    if (duration <= Duration.zero || _lastPosition <= Duration.zero) return;

    _lastReport = DateTime.now();
    final double fraction =
        (_lastPosition.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
    try {
      await _api?.updateProgress(
        lectureId: widget.lectureId,
        progress: fraction,
        watched: fraction >= _watchedThreshold,
      );
    } on ApiException {
      // A failed progress write is not worth interrupting playback for.
    } on NetworkException {
      // Same.
    }
  }

  @override
  Widget build(BuildContext context) {
    return AsyncBuilder<_Playback>(
      future: _future,
      onRetry: _reload,
      loading: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: Text(widget.courseName ?? 'Loading…'),
          backgroundColor: Colors.blueGrey[900],
          foregroundColor: Colors.white,
        ),
        body: const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      ),
      builder: (BuildContext context, _Playback data) {
        final Map<LectureSource, String> sources =
            data.lecture.availableSources;
        if (sources.isEmpty) {
          return Scaffold(
            appBar: AppBar(title: Text(data.lecture.displayName)),
            body: const EmptyView(
              icon: Icons.videocam_off_outlined,
              message: 'This lecture has no recording yet.',
            ),
          );
        }

        // Fall back to whatever source exists if the chosen one is missing.
        final LectureSource source = sources.containsKey(_source)
            ? _source
            : sources.keys.first;

        return LecturePlayer(
          // Rebuilding with a new URL is how a source switch reaches the
          // player; the key keeps state per source rather than per page.
          key: ValueKey<String>('${data.lecture.id}-${source.name}'),
          videoUrl: sources[source]!,
          title: data.lecture.displayName,
          subtitle: data.course.name,
          startAt: data.resumeAt,
          onPositionChanged: _handlePosition,
          onRetry: _reload,
          extraControls: <Widget>[
            if (sources.length > 1) _buildSourceSwitcher(sources, source),
          ],
        );
      },
    );
  }

  Widget _buildSourceSwitcher(
    Map<LectureSource, String> sources,
    LectureSource current,
  ) {
    return PopupMenuButton<LectureSource>(
      tooltip: 'Camera angle',
      initialValue: current,
      onSelected: (LectureSource next) {
        setState(() {
          // Carry the current position across the switch.
          _resumeTarget = _lastPosition;
          _source = next;
        });
      },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<LectureSource>>[
        for (final LectureSource source in sources.keys)
          PopupMenuItem<LectureSource>(
            value: source,
            child: Text(source.label),
          ),
      ],
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Icon(Icons.switch_video_outlined, color: Colors.white, size: 20),
      ),
    );
  }
}
