/// Data classes for the TUM-Live API v2.
///
/// These mirror the messages in gocast's `apiv2/server/apiv2.proto`. The gateway
/// emits lowerCamelCase JSON (`playlistUrl`, `lastRecording`), which is what the
/// `fromJson` constructors below read.
///
/// One rename: gocast calls a single recorded lecture a **Stream**. Here it is a
/// [Lecture], because `Stream` is taken by `dart:async` and the collision would
/// be painful in every file that touches both.
///
/// They all live in one file on purpose — they are small, they change together,
/// and splitting five 30-line DTOs across five files costs more than it saves.
library;

// ---------------------------------------------------------------------------
// Parsing helpers
//
// The API omits fields rather than sending nulls, and a few timestamps come back
// as the proto zero value. Everything below is defensive so one odd record
// cannot take down a whole list.
// ---------------------------------------------------------------------------

int _int(Object? v) => v is int ? v : int.tryParse('$v') ?? 0;
String _string(Object? v) => v is String ? v : '';
bool _bool(Object? v) => v is bool && v;
double _double(Object? v) =>
    v is num ? v.toDouble() : double.tryParse('$v') ?? 0;

/// Parses an RFC3339 timestamp, treating the proto zero value as "unset".
DateTime? _date(Object? v) {
  if (v is! String || v.isEmpty) return null;
  final DateTime? parsed = DateTime.tryParse(v);
  if (parsed == null) return null;
  // gocast sends 0001-01-01T00:00:00Z for a timestamp that was never set.
  if (parsed.year <= 1) return null;
  return parsed;
}

List<T> _list<T>(Object? v, T Function(Map<String, dynamic>) fromJson) {
  if (v is! List) return const <Never>[];
  return v
      .whereType<Map<String, dynamic>>()
      .map(fromJson)
      .toList(growable: false);
}

// ---------------------------------------------------------------------------

/// A teaching term, e.g. winter 2025.
class Semester {
  const Semester({required this.year, required this.teachingTerm});

  factory Semester.fromJson(Map<String, dynamic> json) => Semester(
    year: _int(json['year']),
    teachingTerm: _string(json['teachingTerm']),
  );

  final int year;

  /// `W` for winter, `S` for summer.
  final String teachingTerm;

  /// Used as a dropdown value, so it needs value equality.
  @override
  bool operator ==(Object other) =>
      other is Semester &&
      other.year == year &&
      other.teachingTerm == teachingTerm;

  @override
  int get hashCode => Object.hash(year, teachingTerm);

  @override
  String toString() => 'Semester($teachingTerm$year)';
}

/// What `/semesters` returns: every semester, plus which one is current.
class SemesterList {
  const SemesterList({required this.current, required this.semesters});

  factory SemesterList.fromJson(Map<String, dynamic> json) => SemesterList(
    current: json['current'] is Map<String, dynamic>
        ? Semester.fromJson(json['current'] as Map<String, dynamic>)
        : null,
    semesters: _list(json['semesters'], Semester.fromJson),
  );

  final Semester? current;
  final List<Semester> semesters;
}

/// A course, with however many of its lectures the endpoint chose to include.
///
/// `/courses` (the listing) leaves [lectures] empty and fills [lastRecording];
/// `/courses/{slug}` fills [lectures] with the whole term.
class Course {
  const Course({
    required this.id,
    required this.name,
    required this.slug,
    required this.semester,
    required this.vodEnabled,
    required this.visibility,
    required this.pinned,
    required this.lectures,
    this.lastRecording,
    this.nextLecture,
  });

  factory Course.fromJson(Map<String, dynamic> json) {
    final Object? semester = json['semester'];
    return Course(
      id: _int(json['id']),
      name: _string(json['name']),
      slug: _string(json['slug']),
      semester: semester is Map<String, dynamic>
          ? Semester.fromJson(semester)
          : const Semester(year: 0, teachingTerm: ''),
      vodEnabled: _bool(json['vodEnabled']),
      visibility: _string(json['visibility']),
      pinned: _bool(json['pinned']),
      lectures: _list(json['streams'], Lecture.fromJson),
      lastRecording: json['lastRecording'] is Map<String, dynamic>
          ? Lecture.fromJson(json['lastRecording'] as Map<String, dynamic>)
          : null,
      nextLecture: json['nextLecture'] is Map<String, dynamic>
          ? Lecture.fromJson(json['nextLecture'] as Map<String, dynamic>)
          : null,
    );
  }

  final int id;
  final String name;

  /// The URL-safe identifier, e.g. `WiSe25VKM`. Every stream endpoint needs it
  /// alongside the lecture id.
  final String slug;
  final Semester semester;
  final bool vodEnabled;

  /// One of `public`, `loggedin`, `enrolled`, `hidden`.
  final String visibility;
  final bool pinned;

  /// Empty on listing endpoints. See the class doc.
  final List<Lecture> lectures;

  /// The most recent recorded lecture, if any. Present on listings, which is
  /// what lets the course grid show "last lecture: …" without a second request.
  final Lecture? lastRecording;

  /// The next lecture that has not ended yet, if any.
  final Lecture? nextLecture;

  /// Lectures that can actually be watched now, newest first.
  List<Lecture> get watchableLectures {
    final List<Lecture> playable = lectures
        .where((Lecture l) => l.isPlayable)
        .toList();
    playable.sort((Lecture a, Lecture b) {
      final DateTime? sa = a.start;
      final DateTime? sb = b.start;
      if (sa == null || sb == null) return 0;
      return sb.compareTo(sa);
    });
    return playable;
  }
}

/// One lecture — gocast's `Stream` message.
class Lecture {
  const Lecture({
    required this.id,
    required this.name,
    required this.description,
    required this.courseId,
    required this.start,
    required this.end,
    required this.playlistUrl,
    required this.playlistUrlCam,
    required this.playlistUrlPres,
    required this.liveNow,
    required this.recording,
    required this.ended,
    required this.duration,
    required this.isPlanned,
    required this.isComingUp,
  });

  factory Lecture.fromJson(Map<String, dynamic> json) => Lecture(
    id: _int(json['id']),
    name: _string(json['name']),
    description: _string(json['description']),
    courseId: _int(json['courseId']),
    start: _date(json['start']),
    end: _date(json['end']),
    playlistUrl: _string(json['playlistUrl']),
    playlistUrlCam: _string(json['playlistUrlCam']),
    playlistUrlPres: _string(json['playlistUrlPres']),
    liveNow: _bool(json['liveNow']),
    recording: _bool(json['recording']),
    ended: _bool(json['ended']),
    duration: Duration(seconds: _int(json['duration'])),
    isPlanned: _bool(json['isPlanned']),
    isComingUp: _bool(json['isComingUp']),
  );

  final int id;
  final String name;
  final String description;
  final int courseId;
  final DateTime? start;
  final DateTime? end;

  /// Combined camera + slides. **Signed, and valid for about 7 hours** — never
  /// persist it. Store [id] plus the course slug and fetch a fresh one instead.
  final String playlistUrl;

  /// Camera only. Empty when the lecture was not recorded in two sources.
  final String playlistUrlCam;

  /// Slides only. Empty when the lecture was not recorded in two sources.
  final String playlistUrlPres;

  final bool liveNow;
  final bool recording;
  final bool ended;
  final Duration duration;
  final bool isPlanned;
  final bool isComingUp;

  /// A title for the UI. Many lectures are literally called "Lecture", which is
  /// useless in a list, so fall back to the date.
  String get displayName {
    final String trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.toLowerCase() == 'lecture') {
      final DateTime? s = start;
      if (s != null) {
        final DateTime local = s.toLocal();
        return 'Lecture — ${local.day}.${local.month}.${local.year}';
      }
    }
    return trimmed.isEmpty ? 'Lecture' : trimmed;
  }

  /// Whether there is something to play right now.
  bool get isPlayable => liveNow || playlistUrl.isNotEmpty;

  /// The sources this lecture actually has, for the COMB/CAM/PRES switcher.
  Map<LectureSource, String> get availableSources => <LectureSource, String>{
    if (playlistUrl.isNotEmpty) LectureSource.combined: playlistUrl,
    if (playlistUrlPres.isNotEmpty) LectureSource.presentation: playlistUrlPres,
    if (playlistUrlCam.isNotEmpty) LectureSource.camera: playlistUrlCam,
    // Fused plays the slides and puts the camera over them, so it needs both.
    // Its value is the slides, which is the layer underneath; the camera
    // reaches the player separately as [fusedOverlayUrl].
    if (playlistUrlPres.isNotEmpty && playlistUrlCam.isNotEmpty)
      LectureSource.fused: playlistUrlPres,
  };

  /// The camera track [LectureSource.fused] lays over the slides, or null when
  /// this lecture has no separate camera recording.
  String? get fusedOverlayUrl =>
      playlistUrlCam.isEmpty ? null : playlistUrlCam;
}

/// Which camera angle to play. gocast records up to three per lecture.
///
/// [fused] is the exception: the server has no such recording. It is the slides
/// track with the camera track played over it, composited on the device — see
/// `LecturePlayer.overlayVideoUrl`. gocast's own combined recording packs both
/// into one 16:9 frame and pads the rest with black, which wastes about a
/// quarter of a phone screen held sideways.
enum LectureSource {
  combined('Combined'),
  presentation('Slides'),
  camera('Camera'),
  fused('Fused (beta)');

  const LectureSource(this.label);

  final String label;
}

/// A course paired with one of its lectures — what `/courses/live` returns.
class CourseLecture {
  const CourseLecture({required this.course, required this.lecture});

  factory CourseLecture.fromJson(Map<String, dynamic> json) => CourseLecture(
    course: Course.fromJson(
      (json['course'] as Map<String, dynamic>?) ?? <String, dynamic>{},
    ),
    lecture: Lecture.fromJson(
      (json['stream'] as Map<String, dynamic>?) ?? <String, dynamic>{},
    ),
  );

  final Course course;
  final Lecture lecture;
}

/// How far through a lecture the signed-in user is.
class LectureProgress {
  const LectureProgress({
    required this.lectureId,
    required this.progress,
    required this.watched,
  });

  factory LectureProgress.fromJson(Map<String, dynamic> json) =>
      LectureProgress(
        lectureId: _int(json['streamId']),
        progress: _double(json['progress']).clamp(0, 1).toDouble(),
        watched: _bool(json['watched']),
      );

  final int lectureId;

  /// A fraction between 0 and 1, not seconds. The server stores it that way so
  /// it stays meaningful if the recording is re-cut.
  final double progress;
  final bool watched;

  /// Below this we treat a lecture as untouched, so a stray tap does not put a
  /// "continue watching" badge on something you opened for two seconds.
  static const double startedThreshold = 0.02;

  bool get isStarted => progress > startedThreshold && !watched;
}

/// One entry in a course's up-next list, from `/streams/{slug}/{id}/playlist`.
///
/// Deliberately not a [Lecture]: this endpoint returns a listing shape with no
/// playlist URLs, which is exactly right — the player resolves a signed URL only
/// for the lecture actually being opened.
class PlaylistEntry {
  const PlaylistEntry({
    required this.lectureId,
    required this.courseSlug,
    required this.name,
    required this.start,
    required this.liveNow,
    required this.watched,
    required this.progress,
  });

  factory PlaylistEntry.fromJson(Map<String, dynamic> json) {
    final Object? p = json['streamProgress'];
    final double progress = p is Map<String, dynamic>
        ? _double(p['progress']).clamp(0, 1).toDouble()
        : 0;
    return PlaylistEntry(
      lectureId: _int(json['streamId']),
      courseSlug: _string(json['courseSlug']),
      name: _string(json['streamName']),
      start: _date(json['start']),
      liveNow: _bool(json['liveNow']),
      watched: _bool(json['watched']),
      progress: progress,
    );
  }

  final int lectureId;
  final String courseSlug;
  final String name;
  final DateTime? start;
  final bool liveNow;
  final bool watched;
  final double progress;

  /// Most lectures are literally called "Lecture", which is useless in a list.
  String get displayName {
    final String trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.toLowerCase() == 'lecture') {
      final DateTime? s = start;
      if (s != null) {
        final DateTime l = s.toLocal();
        return 'Lecture — ${l.day}.${l.month}.${l.year}';
      }
    }
    return trimmed.isEmpty ? 'Lecture' : trimmed;
  }

  bool get isStarted =>
      progress > LectureProgress.startedThreshold && !watched;
}

/// A chapter marker inside a lecture.
class VideoSection {
  const VideoSection({
    required this.description,
    required this.startOffset,
    required this.lectureId,
  });

  factory VideoSection.fromJson(Map<String, dynamic> json) => VideoSection(
    description: _string(json['description']),
    startOffset: Duration(
      hours: _int(json['startHours']),
      minutes: _int(json['startMinutes']),
      seconds: _int(json['startSeconds']),
    ),
    lectureId: _int(json['streamId']),
  );

  final String description;
  final Duration startOffset;
  final int lectureId;
}

/// The signed-in user. Only the fields the UI shows are kept.
class TumUser {
  const TumUser({required this.id, required this.name, required this.email});

  factory TumUser.fromJson(Map<String, dynamic> json) => TumUser(
    id: _int(json['id']),
    name: <String>[
      _string(json['name']),
      _string(json['lastName']),
    ].where((String s) => s.isNotEmpty).join(' '),
    email: _string(json['email']),
  );

  final int id;
  final String name;
  final String email;

  String get displayName => name.isNotEmpty ? name : email;
}
