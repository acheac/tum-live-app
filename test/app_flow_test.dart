// Walks the app the way a student does — home screen, into a course, into the
// player — with a fake TUM-Live behind it.
//
// This is the test that would have caught a wrong JSON field name in a screen,
// which the unit tests in api_test.dart cannot: they check that parsing works,
// this checks that the parsed values reach the pixels.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tumlive_player/src/api/models.dart';
import 'package:tumlive_player/src/api/tum_live_api.dart';
import 'package:tumlive_player/src/app_scope.dart';
import 'package:tumlive_player/src/auth/auth_controller.dart';
import 'package:tumlive_player/src/auth/cookie_token_source.dart';
import 'package:tumlive_player/src/auth/credential_store.dart';
import 'package:tumlive_player/src/auth/token_source.dart';
import 'package:tumlive_player/src/home/home_page.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// A stand-in TUM-Live holding one public course with two lectures.
http.Client fakeTumLive({bool noRecording = false}) {
  Map<String, dynamic> lectureWithoutVideo(int id) => <String, dynamic>{
    'id': id,
    'name': 'Lecture',
    'courseId': 42,
    'isPlanned': true,
  };

  Map<String, dynamic> lecture(int id, String date) => <String, dynamic>{
    'id': id,
    'name': 'Lecture',
    'courseId': 42,
    'start': '${date}T08:00:00Z',
    'end': '${date}T10:00:00Z',
    'duration': 7200,
    'playlistUrl': 'https://edge.example/$id/playlist.m3u8?jwt=signed',
    'recording': true,
    'ended': true,
  };

  return MockClient((http.Request request) async {
    final String path = request.url.path;
    Map<String, dynamic>? body;

    if (path.endsWith('/semesters')) {
      body = <String, dynamic>{
        'current': <String, dynamic>{'teachingTerm': 'W', 'year': 2025},
        'semesters': <dynamic>[
          <String, dynamic>{'teachingTerm': 'W', 'year': 2025},
          <String, dynamic>{'teachingTerm': 'S', 'year': 2025},
        ],
      };
    } else if (path.endsWith('/courses/live')) {
      body = <String, dynamic>{'liveCourses': <dynamic>[]};
    } else if (path.endsWith('/courses/analysis')) {
      body = <String, dynamic>{
        'course': <String, dynamic>{
          'id': 42,
          'name': 'Analysis for Informatics',
          'slug': 'analysis',
          'semester': <String, dynamic>{'teachingTerm': 'W', 'year': 2025},
          'visibility': 'public',
          'streams': <dynamic>[
            lecture(101, '2025-10-14'),
            lecture(102, '2025-10-21'),
          ],
        },
      };
    } else if (path.contains('/streams/')) {
      final int id = int.parse(path.split('/').last);
      body = <String, dynamic>{
        'course': <String, dynamic>{
          'id': 42,
          'name': 'Analysis for Informatics',
          'slug': 'analysis',
        },
        'stream': noRecording ? lectureWithoutVideo(id) : lecture(id, '2025-10-21'),
      };
    } else if (path.endsWith('/courses')) {
      body = <String, dynamic>{
        'courses': <dynamic>[
          <String, dynamic>{
            'id': 42,
            'name': 'Analysis for Informatics',
            'slug': 'analysis',
            'semester': <String, dynamic>{'teachingTerm': 'W', 'year': 2025},
            'visibility': 'public',
            'lastRecording': lecture(102, '2025-10-21'),
          },
        ],
      };
    }

    if (body == null) return http.Response('{}', 404);
    return http.Response(
      jsonEncode(body),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  });
}

/// Boots the app's real widget tree against [client].
Future<AuthController> pumpApp(WidgetTester tester, http.Client client) async {
  final AuthController auth = AuthController(
    source: CookieTokenSource(store: MemoryCredentialStore(), client: client),
    client: client,
  );
  // No stored cookie: settles straight into signedOut, which is the state a
  // first-time user sees.
  await auth.restore();

  await tester.pumpWidget(
    AppScope(
      api: TumLiveApi(client: client, tokenProvider: auth.bearerToken),
      auth: auth,
      child: const MaterialApp(home: HomePage()),
    ),
  );
  await tester.pumpAndSettle();
  return auth;
}

void main() {
  testWidgets('the home screen lists public courses when signed out',
      (WidgetTester tester) async {
    await pumpApp(tester, fakeTumLive());

    expect(find.text('Analysis for Informatics'), findsOneWidget);
    expect(find.text('Public courses'), findsOneWidget);
    // Signed out, there is no "My courses" section but there is an invitation.
    expect(find.text('My courses'), findsNothing);
    expect(find.text('Sign in to see your own courses'), findsOneWidget);
  });

  testWidgets('the course card shows when the last lecture was',
      (WidgetTester tester) async {
    await pumpApp(tester, fakeTumLive());

    expect(find.textContaining('Last lecture 21 Oct 2025'), findsOneWidget);
  });

  testWidgets('the semester picker offers the semesters the server knows',
      (WidgetTester tester) async {
    await pumpApp(tester, fakeTumLive());

    expect(find.text('WS 2025'), findsOneWidget);

    await tester.tap(find.byType(DropdownButton<Semester>));
    await tester.pumpAndSettle();

    expect(find.text('SS 2025'), findsWidgets);
  });

  testWidgets('tapping a course opens it and lists its lectures',
      (WidgetTester tester) async {
    await pumpApp(tester, fakeTumLive());

    await tester.tap(find.text('Analysis for Informatics'));
    await tester.pumpAndSettle();

    // Both lectures, newest first, named by date because the server calls them
    // all "Lecture".
    expect(find.textContaining('21.10.2025'), findsOneWidget);
    expect(find.textContaining('14.10.2025'), findsOneWidget);
    // Duration from the `duration` field, not computed from start/end.
    expect(find.textContaining('2:00:00'), findsWidgets);
  });

  testWidgets('a failing server shows a retry instead of a blank screen',
      (WidgetTester tester) async {
    final http.Client broken = MockClient(
      (http.Request request) async => http.Response('boom', 500),
    );

    await pumpApp(tester, broken);

    expect(find.text('Try again'), findsOneWidget);
    expect(find.textContaining('trouble'), findsOneWidget);
  });

  group('opening a lecture', () {
    // Regression: PlayerPage used to resolve its URL from initState, which
    // reads an InheritedWidget too early and threw
    // "dependOnInheritedWidgetOfExactType was called before initState
    // completed". Nothing caught it because no test had ever mounted the page.
    // These do.

    testWidgets('a lecture with no recording says so instead of crashing',
        (WidgetTester tester) async {
      await pumpApp(tester, fakeTumLive(noRecording: true));

      await tester.tap(find.text('Analysis for Informatics'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('21.10.2025'));
      await tester.pumpAndSettle();

      expect(find.textContaining('no recording yet'), findsOneWidget);
    });

    testWidgets('a lecture with a recording reaches the player',
        (WidgetTester tester) async {
      VideoPlayerPlatform.instance = _FailingVideoPlatform();

      await pumpApp(tester, fakeTumLive());

      await tester.tap(find.text('Analysis for Informatics'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('21.10.2025'));
      await tester.pumpAndSettle();

      // Got past PlayerPage: the lecture resolved, a URL was handed to
      // LecturePlayer, and the fake platform refused it.
      expect(find.textContaining('Could not load the video'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('retry-button')), findsOneWidget);
    });

    // Regression: leaving the player calls CoursePage._reload() to pick up the
    // progress you just made. That was written as
    // `setState(() => _future = _load())`, whose arrow body returns the
    // assignment's value — a Future — which setState rejects. It threw on every
    // single back-navigation and no test went this far.
    testWidgets('leaving the player returns to the lecture list',
        (WidgetTester tester) async {
      VideoPlayerPlatform.instance = _FailingVideoPlatform();

      await pumpApp(tester, fakeTumLive());

      await tester.tap(find.text('Analysis for Informatics'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('21.10.2025'));
      await tester.pumpAndSettle();

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // Back on the course page, with the list reloaded.
      expect(find.textContaining('21.10.2025'), findsOneWidget);
      expect(find.textContaining('14.10.2025'), findsOneWidget);
    });
  });

  // Regression: the app used to render a splash screen until AuthStatus stopped
  // being `restoring`. With the WebView source that probe boots a browser and can
  // attempt a silent SSO round trip, so startup blocked for up to two minutes —
  // and forever if the WebView never came up. Nothing needs authentication to
  // browse public courses, so nothing should wait for it.
  testWidgets('the app is usable while the session check is still running',
      (WidgetTester tester) async {
    final http.Client client = fakeTumLive();
    final AuthController auth = AuthController(
      source: _NeverCompletingSource(),
      client: client,
    );
    // Deliberately not awaited: this is the state during a slow probe.
    unawaited(auth.restore());

    await tester.pumpWidget(
      AppScope(
        api: TumLiveApi(client: client, tokenProvider: auth.bearerToken),
        auth: auth,
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(auth.status, AuthStatus.restoring, reason: 'probe still in flight');
    expect(find.text('Analysis for Informatics'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('the home screen retry button reloads without throwing',
      (WidgetTester tester) async {
    // HomePage._reload() had the same arrow-bodied setState bug.
    bool fail = true;
    final http.Client flaky = MockClient((http.Request request) async {
      if (fail) return http.Response('boom', 500);
      return await fakeTumLive().send(
        http.Request(request.method, request.url)..headers.addAll(request.headers),
      ).then((http.StreamedResponse r) => http.Response.fromStream(r));
    });

    await pumpApp(tester, flaky);
    expect(find.text('Try again'), findsOneWidget);

    fail = false;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Analysis for Informatics'), findsOneWidget);
  });
}

/// The smallest platform that satisfies video_player. Every create fails, which
/// puts [LecturePlayer] straight into its error state — enough to prove the
/// player mounted and got a URL, without reimplementing a video pipeline.
class _FailingVideoPlatform extends VideoPlayerPlatform {
  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    throw PlatformException(code: 'VideoError', message: 'no platform in tests');
  }
}

/// A session probe that never answers — a WebView that failed to come up.
class _NeverCompletingSource implements TokenSource {
  final Completer<AccessToken?> _never = Completer<AccessToken?>();

  @override
  bool get supportsInteractiveLogin => true;

  @override
  Future<AccessToken?> mint() => _never.future;

  @override
  Future<void> clear() async {}

  @override
  void dispose() {}
}
