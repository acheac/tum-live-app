/// Turns `(courseSlug, lectureId)` into a playing video, with the rest of the
/// course listed underneath.
///
/// This is the layer that exists because **playlist URLs expire**. gocast signs
/// them with a JWT that lives about seven hours, so the app stores lecture ids
/// and resolves a fresh URL immediately before playback. Never the other way
/// round — that is what made an early hardcoded link rot every day.
///
/// Layout follows the phone video-app convention: the picture sits in a 16:9
/// slot at the top with its controls overlaid, and everything else scrolls
/// below it. In landscape the picture takes the whole screen, because that is
/// the only reason to turn a phone sideways.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_exception.dart';
import '../api/models.dart';
import '../api/tum_live_api.dart';
import '../app_scope.dart';
import '../auth/auth_controller.dart';
import '../common/async_builder.dart';
import '../common/formatting.dart';
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

  /// Shown while the lecture itself is still loading.
  final String? courseName;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

/// Everything the page needs, fetched together.
class _Playback {
  const _Playback({
    required this.lecture,
    required this.course,
    required this.siblings,
    this.resumeAt,
  });

  final Lecture lecture;
  final Course course;

  /// The other lectures in this course, for the list below the player.
  final List<PlaylistEntry> siblings;
  final Duration? resumeAt;
}

class _PlayerPageState extends State<PlayerPage> {
  Future<_Playback>? _future;
  LectureSource _source = LectureSource.combined;

  /// Where to start playback. Seeded from the server's stored progress, then
  /// updated locally so switching camera angles does not lose your place.
  Duration? _resumeTarget;

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
  // registers a dependency, and initState is too early for that.
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
    final TumLiveApi api = _api!;
    final AuthController auth = _auth!;

    final CourseLecture result = await api.getLecture(
      widget.courseSlug,
      widget.lectureId,
    );

    // The sibling list and the stored progress are both optional garnish, so
    // they run together and neither can block playback.
    final List<PlaylistEntry> siblings = await api
        .getLecturePlaylist(widget.courseSlug, widget.lectureId)
        .catchError((Object _) => const <PlaylistEntry>[]);

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
      siblings: siblings,
      resumeAt: _resumeTarget,
    );
  }

  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  /// Opens another lecture from the same course, replacing this page so the
  /// back button returns to the course rather than walking a chain of players.
  void _openSibling(PlaylistEntry entry, Course course) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(
          courseSlug: entry.courseSlug.isNotEmpty
              ? entry.courseSlug
              : widget.courseSlug,
          lectureId: entry.lectureId,
          courseName: course.name,
        ),
      ),
    );
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
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const CircularProgressIndicator(color: Colors.white),
              if (widget.courseName != null) ...<Widget>[
                const SizedBox(height: 16),
                Text(
                  widget.courseName!,
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ],
          ),
        ),
      ),
      builder: (BuildContext context, _Playback data) => _buildLoaded(data),
    );
  }

  Widget _buildLoaded(_Playback data) {
    final Map<LectureSource, String> sources = data.lecture.availableSources;
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

    final Widget player = LecturePlayer(
      // Rebuilding with a new URL is how a source switch reaches the player;
      // the key keeps state per source rather than per page.
      key: ValueKey<String>('${data.lecture.id}-${source.name}'),
      videoUrl: sources[source]!,
      title: data.lecture.displayName,
      subtitle: data.course.name,
      startAt: data.resumeAt,
      onPositionChanged: _handlePosition,
      onRetry: _reload,
      onBack: () => Navigator.of(context).maybePop(),
      extraControls: <Widget>[
        if (sources.length > 1) _buildSourceSwitcher(sources, source),
      ],
    );

    // Sideways means "I want the video bigger", so give it everything.
    final bool landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    if (landscape) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(child: player),
      );
    }

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            AspectRatio(aspectRatio: 16 / 9, child: player),
            Expanded(child: _buildDetails(data)),
          ],
        ),
      ),
    );
  }

  /// Title, meta, and the rest of the course.
  Widget _buildDetails(_Playback data) {
    final ThemeData theme = Theme.of(context);
    final List<PlaylistEntry> siblings = data.siblings
        .where((PlaylistEntry e) => e.lectureId != data.lecture.id)
        .toList(growable: false);

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                data.lecture.displayName,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                <String>[
                  data.course.name,
                  if (data.lecture.start != null)
                    formatLectureDate(data.lecture.start),
                  if (data.lecture.duration > Duration.zero)
                    formatDuration(data.lecture.duration),
                ].join(' · '),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        const Divider(height: 24),
        if (siblings.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('No other lectures in this course.'),
          )
        else ...<Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.playlist_play,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'More in this course',
                  style: theme.textTheme.titleSmall,
                ),
                const Spacer(),
                Text('${siblings.length}', style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(height: 4),
          for (final PlaylistEntry entry in siblings)
            _SiblingTile(
              entry: entry,
              onTap: () => _openSibling(entry, data.course),
            ),
        ],
      ],
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

/// One row in the "more in this course" list.
class _SiblingTile extends StatelessWidget {
  const _SiblingTile({required this.entry, required this.onTap});

  final PlaylistEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListTile(
      dense: true,
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: entry.liveNow
            ? theme.colorScheme.error
            : theme.colorScheme.primaryContainer,
        child: Icon(
          entry.liveNow
              ? Icons.sensors
              : entry.watched
              ? Icons.check
              : Icons.play_arrow,
          size: 16,
          color: entry.liveNow
              ? theme.colorScheme.onError
              : theme.colorScheme.onPrimaryContainer,
        ),
      ),
      title: Text(
        entry.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium,
      ),
      subtitle: entry.isStarted
          ? Padding(
              padding: const EdgeInsets.only(top: 6),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: entry.progress,
                  minHeight: 3,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
              ),
            )
          : null,
      onTap: onTap,
    );
  }
}
