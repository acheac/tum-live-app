/// One course: every lecture of the term, newest first.
///
/// A single request to `/courses/{slug}` returns the whole term with signed
/// playlist URLs already attached, so this page needs one round trip — plus one
/// more for watch progress when signed in.
library;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/tum_live_api.dart';
import '../app_scope.dart';
import '../auth/auth_controller.dart';
import '../common/async_builder.dart';
import '../common/formatting.dart';
import '../player/player_page.dart';

class CoursePage extends StatefulWidget {
  const CoursePage({
    super.key,
    required this.slug,
    required this.semester,
    this.courseName,
  });

  final String slug;
  final Semester semester;

  /// Shown in the app bar while the course itself loads.
  final String? courseName;

  @override
  State<CoursePage> createState() => _CoursePageState();
}

class _CourseData {
  const _CourseData({required this.course, required this.progress});

  final Course course;
  final Map<int, LectureProgress> progress;
}

class _CoursePageState extends State<CoursePage> {
  Future<_CourseData>? _future;

  // The first load happens here rather than in initState: reading an
  // InheritedWidget registers a dependency, which initState is too early for.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= _load();
  }

  Future<_CourseData> _load() async {
    final TumLiveApi api = AppScope.apiOf(context);
    final AuthController auth = AppScope.authOf(context);

    final Course course = await api.getCourse(widget.slug, widget.semester);

    Map<int, LectureProgress> progress = const <int, LectureProgress>{};
    if (auth.isSignedIn && course.lectures.isNotEmpty) {
      try {
        progress = await api.getProgress(
          course.lectures.map((Lecture l) => l.id).toList(),
        );
      } on Object {
        // Progress is decoration here; the lecture list still works without it.
      }
    }
    return _CourseData(course: course, progress: progress);
  }

  /// Re-runs the request behind [_future].
  ///
  /// The body must be a block, not an arrow. `setState(() => _future = _load())`
  /// returns the assignment's value — a Future — and setState rejects a callback
  /// that returns one.
  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.courseName ?? widget.slug)),
      body: AsyncBuilder<_CourseData>(
        future: _future,
        onRetry: _reload,
        builder: (BuildContext context, _CourseData data) {
          final List<Lecture> lectures = data.course.watchableLectures;
          if (lectures.isEmpty) {
            return const EmptyView(
              icon: Icons.videocam_off_outlined,
              message: 'No recordings available for this course yet.',
            );
          }
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: lectures.length,
              itemBuilder: (BuildContext context, int i) {
                final Lecture lecture = lectures[i];
                return _LectureTile(
                  lecture: lecture,
                  progress: data.progress[lecture.id],
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => PlayerPage(
                          courseSlug: data.course.slug,
                          lectureId: lecture.id,
                          courseName: data.course.name,
                        ),
                      ),
                    );
                    // Coming back from the player, progress has moved on.
                    if (mounted) _reload();
                  },
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _LectureTile extends StatelessWidget {
  const _LectureTile({
    required this.lecture,
    required this.progress,
    required this.onTap,
  });

  final Lecture lecture;
  final LectureProgress? progress;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final LectureProgress? p = progress;
    final bool watched = p?.watched ?? false;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Card(
        margin: EdgeInsets.zero,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: <Widget>[
                CircleAvatar(
                  backgroundColor: lecture.liveNow
                      ? theme.colorScheme.error
                      : theme.colorScheme.primaryContainer,
                  child: Icon(
                    lecture.liveNow
                        ? Icons.sensors
                        : watched
                        ? Icons.check
                        : Icons.play_arrow,
                    color: lecture.liveNow
                        ? theme.colorScheme.onError
                        : theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        lecture.displayName,
                        style: theme.textTheme.titleSmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        <String>[
                          if (lecture.start != null)
                            formatLectureDate(lecture.start),
                          if (lecture.duration > Duration.zero)
                            formatDuration(lecture.duration),
                        ].join(' · '),
                        style: theme.textTheme.bodySmall,
                      ),
                      // The thin bar YouTube puts under a half-watched video.
                      if (p != null && p.isStarted) ...<Widget>[
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: p.progress,
                            minHeight: 3,
                            backgroundColor: theme.colorScheme.surfaceContainerHighest,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (lecture.liveNow)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Chip(
                      label: const Text('LIVE'),
                      backgroundColor: theme.colorScheme.errorContainer,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
