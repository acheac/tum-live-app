/// A typed client for the TUM-Live API v2.
///
/// Base URL: `https://tum.live/api/v2` — docs at <https://tum.live/api/v2/docs>.
/// The endpoints here are declared in gocast's `apiv2/server/apiv2.proto`.
///
/// Two things worth knowing before you extend this:
///
/// 1. **Public courses need no authentication at all.** Browsing and playing a
///    public lecture works signed out. Only `enrolled`/`loggedin` courses,
///    watch progress and bookmarks need a token.
/// 2. **Playlist URLs are signed and expire in about 7 hours.** Anything that
///    returns a [Lecture] returns a freshly signed one, so always re-fetch
///    before playback rather than storing the URL.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';
import 'models.dart';

/// Supplies the bearer token for authenticated calls, or null when signed out.
///
/// This indirection is what keeps the API layer unaware of how login works —
/// swap the WebView flow for a backend later and nothing in this file changes.
typedef BearerTokenProvider = Future<String?> Function();

class TumLiveApi {
  TumLiveApi({
    http.Client? client,
    this.baseUrl = defaultBaseUrl,
    this.tokenProvider,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client();

  static const String defaultBaseUrl = 'https://tum.live/api/v2';

  /// The host the SSO flow runs against, derived from [baseUrl].
  static const String defaultOrigin = 'https://tum.live';

  final String baseUrl;
  final BearerTokenProvider? tokenProvider;
  final Duration timeout;
  final http.Client _client;

  void close() => _client.close();

  // -------------------------------------------------------------------------
  // Meta
  // -------------------------------------------------------------------------

  /// Every semester TUM-Live knows about, plus the current one.
  Future<SemesterList> getSemesters() async =>
      SemesterList.fromJson(await _getJson('/semesters'));

  // -------------------------------------------------------------------------
  // Courses
  // -------------------------------------------------------------------------

  /// Courses anyone may see, for one semester. Works signed out.
  Future<List<Course>> getPublicCourses(Semester semester) async {
    final Map<String, dynamic> json = await _getJson(
      '/courses',
      query: _semesterQuery(semester),
    );
    return _courses(json);
  }

  /// The signed-in user's enrolled courses. Requires a token.
  Future<List<Course>> getEnrolledCourses(Semester semester) async {
    final Map<String, dynamic> json = await _getJson(
      '/courses/enrolled',
      query: _semesterQuery(semester),
    );
    return _courses(json);
  }

  /// Courses the user pinned. Requires a token.
  Future<List<Course>> getPinnedCourses() async =>
      _courses(await _getJson('/courses/pinned'));

  /// Everything streaming right now, across all courses. Works signed out.
  ///
  /// Note the different response shape: this one returns course+lecture pairs,
  /// not bare courses.
  Future<List<CourseLecture>> getLiveCourses() async {
    final Map<String, dynamic> json = await _getJson('/courses/live');
    final Object? raw = json['liveCourses'];
    if (raw is! List) return const <CourseLecture>[];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(CourseLecture.fromJson)
        .toList(growable: false);
  }

  /// One course with **all its lectures**, each carrying a signed playlist URL.
  ///
  /// This is the request the course page is built on: one round trip gives you
  /// a playable term.
  Future<Course> getCourse(String slug, Semester semester) async {
    final Map<String, dynamic> json = await _getJson(
      '/courses/$slug',
      query: _semesterQuery(semester),
    );
    final Object? course = json['course'];
    if (course is! Map<String, dynamic>) {
      throw ApiException(200, 'Course $slug came back without a body.');
    }
    return Course.fromJson(course);
  }

  /// Pins or unpins a course. Requires a token.
  Future<void> setCoursePinned({
    required int courseId,
    required bool pinned,
  }) => _sendJson('POST', '/courses/$courseId/pin', body: <String, dynamic>{
    'courseId': courseId,
    'pin': pinned,
  });

  // -------------------------------------------------------------------------
  // Lectures
  // -------------------------------------------------------------------------

  /// One lecture, with freshly signed playlist URLs.
  ///
  /// Call this immediately before playback — see the note at the top of the file.
  Future<CourseLecture> getLecture(String slug, int lectureId) async {
    final Map<String, dynamic> json = await _getJson('/streams/$slug/$lectureId');
    return CourseLecture.fromJson(json);
  }

  /// Chapter markers for a lecture. Often empty — most courses never set them.
  Future<List<VideoSection>> getSections(String slug, int lectureId) async {
    final Map<String, dynamic> json = await _getJson(
      '/streams/$slug/$lectureId/sections',
    );
    final Object? raw = json['sections'];
    if (raw is! List) return const <VideoSection>[];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(VideoSection.fromJson)
        .toList(growable: false);
  }

  // -------------------------------------------------------------------------
  // Progress — what makes "continue watching" work
  // -------------------------------------------------------------------------

  /// Watch progress for several lectures at once. Requires a token.
  ///
  /// The repeated query parameter is spelled `stream_ids` (the proto field
  /// name); grpc-gateway also accepts the camelCase form.
  Future<Map<int, LectureProgress>> getProgress(List<int> lectureIds) async {
    if (lectureIds.isEmpty) return const <int, LectureProgress>{};
    final Map<String, dynamic> json = await _getJson(
      '/progress',
      query: <String, List<String>>{
        'stream_ids': lectureIds.map((int id) => '$id').toList(),
      },
    );
    final Object? raw = json['progressBatch'];
    if (raw is! List) return const <int, LectureProgress>{};
    return <int, LectureProgress>{
      for (final Map<String, dynamic> item
          in raw.whereType<Map<String, dynamic>>())
        LectureProgress.fromJson(item).lectureId:
            LectureProgress.fromJson(item),
    };
  }

  /// Stores how far through a lecture the user is. Requires a token.
  ///
  /// [progress] is a fraction of the whole lecture, not seconds.
  Future<void> updateProgress({
    required int lectureId,
    required double progress,
    bool watched = false,
  }) => _sendJson(
    'PATCH',
    '/progress/$lectureId',
    body: <String, dynamic>{
      'streamId': lectureId,
      'progress': progress.clamp(0, 1),
      'watched': watched,
    },
  );

  // -------------------------------------------------------------------------
  // User
  // -------------------------------------------------------------------------

  /// The signed-in user. Requires a token — this is also how the login screen
  /// checks that a pasted session cookie actually works.
  Future<TumUser> getCurrentUser() async {
    final Map<String, dynamic> json = await _getJson('/users/me');
    final Object? user = json['user'];
    if (user is! Map<String, dynamic>) {
      throw ApiException(200, 'No user in the response.');
    }
    return TumUser.fromJson(user);
  }

  // -------------------------------------------------------------------------
  // Plumbing
  // -------------------------------------------------------------------------

  Map<String, List<String>> _semesterQuery(Semester semester) =>
      <String, List<String>>{
        'year': <String>['${semester.year}'],
        'term': <String>[semester.teachingTerm],
      };

  List<Course> _courses(Map<String, dynamic> json) {
    final Object? raw = json['courses'];
    if (raw is! List) return const <Course>[];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(Course.fromJson)
        .toList(growable: false);
  }

  Uri _uri(String path, Map<String, List<String>>? query) {
    final Uri base = Uri.parse('$baseUrl$path');
    if (query == null || query.isEmpty) return base;
    return base.replace(queryParameters: query);
  }

  Future<Map<String, dynamic>> _getJson(
    String path, {
    Map<String, List<String>>? query,
  }) => _sendJson('GET', path, query: query);

  Future<Map<String, dynamic>> _sendJson(
    String method,
    String path, {
    Map<String, List<String>>? query,
    Map<String, dynamic>? body,
  }) async {
    final Uri uri = _uri(path, query);
    final http.Request request = http.Request(method, uri);
    request.headers['Accept'] = 'application/json';
    // Identifying the client is basic courtesy towards a university service.
    request.headers['User-Agent'] = 'tumlive_player/0.1 (Flutter prototype)';

    final String? token = await tokenProvider?.call();
    if (token != null && token.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $token';
    }
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    final http.Response response;
    try {
      final http.StreamedResponse streamed = await _client
          .send(request)
          .timeout(timeout);
      response = await http.Response.fromStream(streamed);
    } on TimeoutException catch (e) {
      throw NetworkException(e, uri: uri);
    } catch (e) {
      throw NetworkException(e, uri: uri);
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        response.statusCode,
        _errorMessage(response.body),
        uri: uri,
      );
    }

    if (response.body.isEmpty) return <String, dynamic>{};
    final Object? decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw ApiException(response.statusCode, 'Unexpected response shape.',
          uri: uri);
    }
    return decoded;
  }

  /// grpc-gateway reports failures as `{"message": "...", "code": 7}`.
  String _errorMessage(String body) {
    if (body.isEmpty) return '';
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final Object? message = decoded['message'] ?? decoded['error'];
        if (message is String && message.isNotEmpty) return message;
      }
    } on FormatException {
      // Not JSON — fall through and use the raw body.
    }
    return body.length > 200 ? '${body.substring(0, 200)}…' : body;
  }
}
