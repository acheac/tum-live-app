// This is a command-line tool: printing is its entire purpose.
// ignore_for_file: avoid_print

/// Talks to the real TUM-Live API and prints what comes back.
///
/// Run with:  dart run tool/api_smoke.dart
///
/// This works as a plain Dart script — no Flutter, no simulator — because
/// `lib/src/api/` deliberately imports nothing from Flutter. That constraint is
/// worth keeping: it makes the whole network layer testable in a second.
///
/// Use it when a response shape looks wrong, or after changing a model.
library;

import 'package:tumlive_player/src/api/models.dart';
import 'package:tumlive_player/src/api/tum_live_api.dart';

Future<void> main(List<String> args) async {
  final TumLiveApi api = TumLiveApi();

  try {
    final SemesterList semesters = await api.getSemesters();
    final Semester current =
        semesters.current ?? const Semester(year: 2025, teachingTerm: 'W');
    print('current semester : ${current.teachingTerm}${current.year}');
    print('known semesters  : ${semesters.semesters.length}');

    final List<Course> courses = await api.getPublicCourses(current);
    print('public courses   : ${courses.length} in '
        '${current.teachingTerm}${current.year}');

    // Fall back to a semester that definitely has public courses, so the smoke
    // test still says something useful during the semester break.
    final Course? sample = courses.isNotEmpty
        ? courses.firstWhere(
            (Course c) => c.lastRecording != null,
            orElse: () => courses.first,
          )
        : await _fallbackCourse(api);
    if (sample == null) {
      print('no public course with a recording found; stopping here');
      return;
    }

    print('sample course    : ${sample.name} (${sample.slug})');

    final Course full = await api.getCourse(sample.slug, sample.semester);
    final List<Lecture> lectures = full.watchableLectures;
    print('lectures         : ${lectures.length} playable');
    if (lectures.isEmpty) return;

    final Lecture lecture = lectures.first;
    print('sample lecture   : ${lecture.displayName}');
    print('  start          : ${lecture.start}');
    print('  duration       : ${lecture.duration}');
    print('  sources        : ${lecture.availableSources.keys.map((LectureSource s) => s.label).join(', ')}');
    print('  playlist       : ${_truncate(lecture.playlistUrl)}');

    // The single most important property to check: this URL is signed and
    // short-lived, so it must arrive fresh on every fetch.
    final CourseLecture resolved = await api.getLecture(full.slug, lecture.id);
    print('refetched url    : ${_truncate(resolved.lecture.playlistUrl)}');
    print('  same as above? : '
        '${resolved.lecture.playlistUrl == lecture.playlistUrl}');

    final List<VideoSection> sections =
        await api.getSections(full.slug, lecture.id);
    print('sections         : ${sections.length}');
  } finally {
    api.close();
  }
}

/// A known-public course, used when the current semester has none listed yet.
Future<Course?> _fallbackCourse(TumLiveApi api) async {
  const Semester winter2025 = Semester(year: 2025, teachingTerm: 'W');
  final List<Course> courses = await api.getPublicCourses(winter2025);
  if (courses.isEmpty) return null;
  return courses.firstWhere(
    (Course c) => c.lastRecording != null,
    orElse: () => courses.first,
  );
}

String _truncate(String value, [int max = 70]) =>
    value.length <= max ? value : '${value.substring(0, max)}…';
