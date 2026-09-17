/// One course: every lecture of the term, newest first.
///
/// A single request to `/courses/{slug}` returns the whole term with signed
/// playlist URLs already attached, so this page needs one round trip — plus one
/// more for watch progress when signed in.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/tum_live_api.dart';
import '../app_scope.dart';
import '../auth/auth_controller.dart';
import '../common/async_builder.dart';
import '../common/formatting.dart';
import '../common/pin_button.dart';
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

  /// The loaded course, kept outside the future so the app bar can reach it.
  ///
  /// The bar is built above [AsyncBuilder], one frame before the request
  /// lands, and the pin button needs the course's id — which only the response
  /// carries. Null until then, which is also what hides the button while the
  /// page is still loading.
  Course? _course;

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
    // setState rather than a plain assignment: the app bar is a sibling of the
    // AsyncBuilder, so nothing else would rebuild it when the course arrives.
    if (mounted) setState(() => _course = course);
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

  /// How many lines of the header the course name may take.
  static const int _titleMaxLines = 3;

  /// The title style, a size down from AppBar's own.
  ///
  /// Course names here are long — "Fachschaftsvollversammlung - School of
  /// Computation, Information and Technology" is one — and at AppBar's default
  /// titleLarge (22sp) even the first compound word is wider than the bar, so
  /// Flutter breaks it mid-word: "Fachschaftsvollversammlun / g". Dropping to
  /// titleMedium's size fits that word on one line and lets the rest wrap at
  /// spaces, which is also what makes [_titleMaxLines] lines enough.
  ///
  /// Only the size is overridden. Taking titleMedium wholesale would take its
  /// colour too, which belongs to body text rather than to the app bar.
  TextStyle? get _titleStyle {
    final ThemeData theme = Theme.of(context);
    final TextStyle? base =
        theme.appBarTheme.titleTextStyle ?? theme.textTheme.titleLarge;
    return base?.copyWith(
      fontSize: theme.textTheme.titleMedium?.fontSize ?? 16,
    );
  }

  /// Room for [_titleMaxLines] lines of [_titleStyle], and no more.
  ///
  /// An AppBar's height is fixed rather than intrinsic, so the extra lines have
  /// to be paid for up front — a title that wraps inside a 56dp bar is clipped
  /// rather than ellipsized, which reads as a rendering bug. Derived from the
  /// style rather than hardcoded because it scales with the user's font size:
  /// at 200% a literal clips exactly the long names this exists to show.
  double get _titleBarHeight {
    final TextStyle? style = _titleStyle;
    final double fontSize = MediaQuery.textScalerOf(
      context,
    ).scale(style?.fontSize ?? 16);
    // Same vertical breathing room a default one-line toolbar leaves.
    return math.max(
      kToolbarHeight,
      _titleMaxLines * fontSize * (style?.height ?? 1.3) + 24,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: _titleBarHeight,
        titleTextStyle: _titleStyle,
        // AppBar wraps its title in a DefaultTextStyle with
        // `softWrap: false, overflow: ellipsis`, so the Material default is a
        // single clipped line however much room the bar has. Restating all
        // three here is what overrides that inherited style.
        title: Text(
          widget.courseName ?? widget.slug,
          softWrap: true,
          maxLines: _titleMaxLines,
          overflow: TextOverflow.ellipsis,
        ),
        // Right after the name, which is where the thing being pinned is.
        // Only once the course has loaded: pinning needs its id, and the bar
        // is built before the request lands.
        actions: <Widget>[
          if (_course != null)
            PinButton(course: _course!, compact: true),
        ],
      ),
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
