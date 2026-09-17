// Tests for the network layer.
//
// These use package:http's MockClient rather than a real server, so they are
// fast and deterministic. What they are really guarding is the JSON parsing:
// a field renamed upstream should fail here, loudly, not silently produce a
// screen full of empty cards.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tumlive_player/src/player/player_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tumlive_player/src/api/api_exception.dart';
import 'package:tumlive_player/src/api/models.dart';
import 'package:tumlive_player/src/api/tum_live_api.dart';

/// Builds an api whose every request is answered by [handler].
TumLiveApi apiWith(
  Future<http.Response> Function(http.Request request) handler, {
  BearerTokenProvider? tokenProvider,
}) => TumLiveApi(
  client: MockClient(handler),
  tokenProvider: tokenProvider,
);

http.Response json(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

void main() {
  group('course parsing', () {
    test('reads a public course listing', () async {
      final TumLiveApi api = apiWith(
        (http.Request request) async => json(<String, dynamic>{
          'courses': <dynamic>[
            <String, dynamic>{
              'id': 1871,
              'name': 'Precourse Mathematics',
              'slug': 'WiSe25VKM',
              'semester': <String, dynamic>{'teachingTerm': 'W', 'year': 2025},
              'visibility': 'public',
              'vodEnabled': true,
            },
          ],
        }),
      );

      final List<Course> courses = await api.getPublicCourses(
        const Semester(year: 2025, teachingTerm: 'W'),
      );

      expect(courses, hasLength(1));
      expect(courses.single.slug, 'WiSe25VKM');
      expect(courses.single.semester.year, 2025);
      expect(courses.single.visibility, 'public');
    });

    test('a course listing puts year and term in the query string', () async {
      late Uri seen;
      final TumLiveApi api = apiWith((http.Request request) async {
        seen = request.url;
        return json(<String, dynamic>{'courses': <dynamic>[]});
      });

      await api.getPublicCourses(const Semester(year: 2024, teachingTerm: 'S'));

      expect(seen.queryParameters['year'], '2024');
      expect(seen.queryParameters['term'], 'S');
    });

    test('lectures come from the `streams` field', () async {
      final TumLiveApi api = apiWith(
        (http.Request request) async => json(<String, dynamic>{
          'course': <String, dynamic>{
            'id': 1,
            'name': 'Course',
            'slug': 'c',
            'streams': <dynamic>[
              <String, dynamic>{
                'id': 62189,
                'name': 'Lecture',
                'start': '2025-10-10T06:00:00Z',
                'duration': 9900,
                'playlistUrl': 'https://edge.example/playlist.m3u8?jwt=abc',
              },
            ],
          },
        }),
      );

      final Course course = await api.getCourse(
        'c',
        const Semester(year: 2025, teachingTerm: 'W'),
      );

      expect(course.lectures, hasLength(1));
      final Lecture lecture = course.lectures.single;
      expect(lecture.id, 62189);
      expect(lecture.duration, const Duration(seconds: 9900));
      expect(lecture.isPlayable, isTrue);
      // "Lecture" is useless in a list, so it falls back to the date.
      expect(lecture.displayName, contains('10.10.2025'));
    });

    test('the proto zero timestamp becomes null, not year 1', () async {
      final Lecture lecture = Lecture.fromJson(<String, dynamic>{
        'id': 1,
        'liveNowTimestamp': '0001-01-01T00:00:00Z',
        'start': '0001-01-01T00:00:00Z',
      });
      expect(lecture.start, isNull);
    });

    test('live courses are read from `liveCourses`, not `courses`', () async {
      final TumLiveApi api = apiWith(
        (http.Request request) async => json(<String, dynamic>{
          'liveCourses': <dynamic>[
            <String, dynamic>{
              'course': <String, dynamic>{'id': 1, 'name': 'C', 'slug': 'c'},
              'stream': <String, dynamic>{'id': 9, 'liveNow': true},
            },
          ],
        }),
      );

      final List<CourseLecture> live = await api.getLiveCourses();
      expect(live, hasLength(1));
      expect(live.single.lecture.liveNow, isTrue);
      expect(live.single.course.slug, 'c');
    });

    test('a malformed entry does not take the whole list down', () async {
      final TumLiveApi api = apiWith(
        (http.Request request) async => json(<String, dynamic>{
          'courses': <dynamic>[
            'not a course',
            <String, dynamic>{'id': 2, 'name': 'Fine', 'slug': 'fine'},
          ],
        }),
      );

      final List<Course> courses = await api.getPublicCourses(
        const Semester(year: 2025, teachingTerm: 'W'),
      );
      expect(courses, hasLength(1));
      expect(courses.single.slug, 'fine');
    });
  });

  group('sources', () {
    test('only non-empty playlists are offered as sources', () {
      final Lecture lecture = Lecture.fromJson(<String, dynamic>{
        'id': 1,
        'playlistUrl': 'comb',
        'playlistUrlPres': '',
        'playlistUrlCam': 'cam',
      });
      expect(
        lecture.availableSources.keys,
        <LectureSource>[LectureSource.combined, LectureSource.camera],
      );
    });

    test('fused needs both the slides and the camera', () {
      Lecture withUrls(String pres, String cam) => Lecture.fromJson(
        <String, dynamic>{
          'id': 1,
          'playlistUrl': 'comb',
          'playlistUrlPres': pres,
          'playlistUrlCam': cam,
        },
      );

      // One layer alone composites into nothing.
      expect(
        withUrls('pres', '').availableSources.keys,
        isNot(contains(LectureSource.fused)),
      );
      expect(
        withUrls('', 'cam').availableSources.keys,
        isNot(contains(LectureSource.fused)),
      );

      final Lecture both = withUrls('pres', 'cam');
      expect(both.availableSources.keys, contains(LectureSource.fused));
      // Fused plays the slides; the camera goes over the top separately.
      expect(both.availableSources[LectureSource.fused], 'pres');
      expect(both.fusedOverlayUrl, 'cam');
    });
  });

  group('remembered camera angle', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('nothing stored means no opinion', () async {
      expect(await const SourcePreference().read(), isNull);
    });

    test('a written angle comes back', () async {
      const SourcePreference prefs = SourcePreference();
      await prefs.write(LectureSource.fused);
      expect(await prefs.read(), LectureSource.fused);
    });

    test('an unknown stored name is ignored rather than crashing', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'tumlive.lecture_source': 'holograph',
      });
      expect(await const SourcePreference().read(), isNull);
    });

    test('angles are stored by name, not by index', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'tumlive.lecture_source': 'presentation',
      });
      // Storing the index would have broken the moment `fused` was added to
      // the enum, silently switching everyone to a different angle.
      expect(await const SourcePreference().read(), LectureSource.presentation);
    });
  });

  group('authentication', () {
    test('a token is sent as a bearer header when one is available', () async {
      late http.Request seen;
      final TumLiveApi api = apiWith(
        (http.Request request) async {
          seen = request;
          return json(<String, dynamic>{'courses': <dynamic>[]});
        },
        tokenProvider: () async => 'token-123',
      );

      await api.getPinnedCourses();

      expect(seen.headers['Authorization'], 'Bearer token-123');
    });

    test('no Authorization header at all when signed out', () async {
      late http.Request seen;
      final TumLiveApi api = apiWith(
        (http.Request request) async {
          seen = request;
          return json(<String, dynamic>{'courses': <dynamic>[]});
        },
        tokenProvider: () async => null,
      );

      await api.getPublicCourses(const Semester(year: 2025, teachingTerm: 'W'));

      expect(seen.headers.containsKey('Authorization'), isFalse);
    });

    test('401 surfaces as an unauthorized ApiException', () async {
      final TumLiveApi api = apiWith(
        (http.Request request) async =>
            json(<String, dynamic>{'message': 'unauthenticated'}, status: 401),
      );

      await expectLater(
        api.getCurrentUser(),
        throwsA(
          isA<ApiException>()
              .having((ApiException e) => e.isUnauthorized, 'isUnauthorized', isTrue)
              .having((ApiException e) => e.message, 'message', 'unauthenticated'),
        ),
      );
    });
  });

  group('progress', () {
    test('batch reads use repeated stream_ids and key by lecture', () async {
      late Uri seen;
      final TumLiveApi api = apiWith((http.Request request) async {
        seen = request.url;
        return json(<String, dynamic>{
          'progressBatch': <dynamic>[
            <String, dynamic>{'streamId': 1, 'progress': 0.5, 'watched': false},
            <String, dynamic>{'streamId': 2, 'progress': 1.0, 'watched': true},
          ],
        });
      });

      final Map<int, LectureProgress> progress =
          await api.getProgress(<int>[1, 2]);

      expect(seen.queryParametersAll['stream_ids'], <String>['1', '2']);
      expect(progress[1]!.progress, 0.5);
      expect(progress[1]!.isStarted, isTrue);
      expect(progress[2]!.watched, isTrue);
      // A finished lecture is not "continue watching".
      expect(progress[2]!.isStarted, isFalse);
    });

    test('an empty id list skips the request entirely', () async {
      bool called = false;
      final TumLiveApi api = apiWith((http.Request request) async {
        called = true;
        return json(<String, dynamic>{});
      });

      expect(await api.getProgress(<int>[]), isEmpty);
      expect(called, isFalse);
    });

    test('writing progress PATCHes the lecture and clamps the fraction',
        () async {
      late http.Request seen;
      final TumLiveApi api = apiWith((http.Request request) async {
        seen = request;
        return json(<String, dynamic>{});
      });

      await api.updateProgress(lectureId: 7, progress: 1.4, watched: true);

      expect(seen.method, 'PATCH');
      expect(seen.url.path, endsWith('/progress/7'));
      final Map<String, dynamic> body =
          jsonDecode(seen.body) as Map<String, dynamic>;
      expect(body['progress'], 1.0);
      expect(body['watched'], isTrue);
    });
  });

  group('transport', () {
    test('a connection failure becomes a NetworkException', () async {
      final TumLiveApi api = apiWith(
        (http.Request request) async => throw const SocketishError(),
      );

      await expectLater(
        api.getSemesters(),
        throwsA(isA<NetworkException>()),
      );
    });

    test('a non-JSON error body still produces a usable message', () async {
      final TumLiveApi api = apiWith(
        (http.Request request) async => http.Response('gateway boom', 502),
      );

      await expectLater(
        api.getSemesters(),
        throwsA(
          isA<ApiException>().having(
            (ApiException e) => e.userMessage,
            'userMessage',
            contains('trouble'),
          ),
        ),
      );
    });
  });
}

/// Stand-in for a socket failure; MockClient has no way to fake one directly.
class SocketishError implements Exception {
  const SocketishError();
}
