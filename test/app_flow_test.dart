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
import 'package:shared_preferences/shared_preferences.dart';
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
import 'package:tumlive_player/src/player/lecture_player.dart';
import 'package:tumlive_player/src/player/player_page.dart';
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
    'playlistUrlPres': 'https://edge.example/$id/pres.m3u8?jwt=signed',
    'playlistUrlCam': 'https://edge.example/$id/cam.m3u8?jwt=signed',
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
    } else if (path.endsWith('/playlist')) {
      body = <String, dynamic>{
        'entries': <dynamic>[
          <String, dynamic>{
            'streamId': 102,
            'courseSlug': 'analysis',
            'streamName': 'Lecture',
            'start': '2025-10-21T08:00:00Z',
            'streamProgress': <String, dynamic>{'progress': 0.4},
          },
          <String, dynamic>{
            'streamId': 101,
            'courseSlug': 'analysis',
            'streamName': 'Lecture',
            'start': '2025-10-14T08:00:00Z',
            'watched': true,
          },
        ],
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
  // The player reads the remembered camera angle before it can build, and
  // there is no preferences plugin under `flutter test` — without this the
  // page waits on a future that never lands and every pumpAndSettle times out.
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

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

      // Not tester.pageBack(): the player has no AppBar to hold a default back
      // button. Its back affordance is overlaid on the picture instead, and in
      // the failure state it comes from LecturePlayer rather than the chrome.
      await tester.tap(find.byKey(const ValueKey<String>('player-back-button')));
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

  testWidgets('the player lists the rest of the course underneath',
      (WidgetTester tester) async {
    // A phone-shaped window, so the 16:9 arithmetic below is worth checking.
    // setSurfaceSize does not reach MediaQuery here; setting the view does.
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    VideoPlayerPlatform.instance = _FailingVideoPlatform();

    await pumpApp(tester, fakeTumLive());
    await tester.tap(find.text('Analysis for Informatics'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('21.10.2025'));
    await tester.pumpAndSettle();

    // Both lectures are listed, the one playing included and marked. Dropping
    // it made the list shift by a row on every switch and gave no sense of
    // where in the course you were.
    expect(find.text('More in this course'), findsOneWidget);
    expect(find.textContaining('14.10.2025'), findsOneWidget);
    expect(find.byKey(const ValueKey('now-playing')), findsOneWidget);

    // And the video sits in a fixed 16:9 slot rather than filling the screen,
    // which is what leaves room for the list. The slot is a sized box rather
    // than an AspectRatio so that the element chain is the same in fullscreen
    // and the video survives the switch — see PlayerPage.build.
    final Size slot = tester.getSize(find.byType(LecturePlayer));
    expect(slot.width, closeTo(400, 0.5));
    expect(slot.height, closeTo(400 * 9 / 16, 0.5));
  });

  testWidgets('tapping a sibling swaps the lecture without rebuilding the page', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final _WorkingVideoPlatform video = _WorkingVideoPlatform();
    VideoPlayerPlatform.instance = video;

    await pumpApp(tester, fakeTumLive());
    await tester.tap(find.text('Analysis for Informatics'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('21.10.2025'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    video.completeInitialization();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Playing 102, dated 21.10.
    expect(find.textContaining('21.10.2025'), findsWidgets);
    final Element pageBefore = tester.element(find.byType(PlayerPage));

    await tester.tap(find.textContaining('14.10.2025'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    // The swap builds a second controller for the new video — that part is
    // meant to reload.
    video.completeInitialization();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The list is still there throughout — no full-page spinner, no new route.
    expect(find.text('More in this course'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    // The same PlayerPage element throughout: no pushReplacement, no rebuild
    // of the screen. The video inside it is a different controller, which is
    // the part that is supposed to change.
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(
      identical(tester.element(find.byType(PlayerPage)), pageBefore),
      isTrue,
    );
    // And the marker moved to the lecture now playing.
    expect(find.byKey(const ValueKey('now-playing')), findsOneWidget);
    // Which is the animated one, and only on that row.
    expect(find.byKey(const ValueKey('playing-bars')), findsOneWidget);
  });

  testWidgets('back leaves fullscreen first and the lecture second', (
    WidgetTester tester,
  ) async {
    final _WorkingVideoPlatform video = _WorkingVideoPlatform();
    VideoPlayerPlatform.instance = video;

    await pumpApp(tester, fakeTumLive());
    await tester.tap(find.text('Analysis for Informatics'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('21.10.2025'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    video.completeInitialization();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byKey(const ValueKey('fullscreen-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('More in this course'), findsNothing);

    // First back: out of fullscreen, still on the lecture.
    await tester.tap(find.byKey(const ValueKey('player-back-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(find.text('More in this course'), findsOneWidget);

    // Second back: out of the lecture.
    await tester.tap(find.byKey(const ValueKey('player-back-button')));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerPage), findsNothing);
  });

  testWidgets('the system back gesture also leaves fullscreen first', (
    WidgetTester tester,
  ) async {
    final _WorkingVideoPlatform video = _WorkingVideoPlatform();
    VideoPlayerPlatform.instance = video;

    /// What Android's back button sends the engine.
    Future<void> systemBack() => tester.binding.defaultBinaryMessenger
        .handlePlatformMessage(
          'flutter/navigation',
          const JSONMethodCodec().encodeMethodCall(
            const MethodCall('popRoute'),
          ),
          (_) {},
        );

    await pumpApp(tester, fakeTumLive());
    await tester.tap(find.text('Analysis for Informatics'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('21.10.2025'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    video.completeInitialization();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byKey(const ValueKey('fullscreen-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('More in this course'), findsNothing);

    // First back: out of fullscreen, still on the lecture.
    await systemBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(find.text('More in this course'), findsOneWidget);

    // Second back: out of the lecture.
    await systemBack();
    await tester.pumpAndSettle();
    expect(find.byType(PlayerPage), findsNothing);
  });

  testWidgets('the remembered camera angle is used for the next lecture', (
    WidgetTester tester,
  ) async {
    // As if the user had picked Slides on some earlier lecture.
    SharedPreferences.setMockInitialValues(<String, Object>{
      'tumlive.lecture_source': 'presentation',
    });
    VideoPlayerPlatform.instance = _FailingVideoPlatform();

    await pumpApp(tester, fakeTumLive());
    await tester.tap(find.text('Analysis for Informatics'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('21.10.2025'));
    await tester.pumpAndSettle();

    // The player is keyed by lecture and angle, so the key says which angle
    // the page actually opened on without reaching into private state.
    final LecturePlayer player = tester.widget<LecturePlayer>(
      find.byType(LecturePlayer),
    );
    expect((player.key! as ValueKey<String>).value, endsWith('-presentation'));
  });

  testWidgets('the camera-angle menu offers every angle, fused included', (
    WidgetTester tester,
  ) async {
    final _WorkingVideoPlatform video = _WorkingVideoPlatform();
    VideoPlayerPlatform.instance = video;

    await pumpApp(tester, fakeTumLive());
    await tester.tap(find.text('Analysis for Informatics'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('21.10.2025'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    video.completeInitialization();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The switcher is a fullscreen-only control.
    await tester.tap(find.byKey(const ValueKey('fullscreen-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byTooltip('Camera angle'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // This fixture has all three tracks, so fused is composable and offered.
    expect(find.text('Combined'), findsOneWidget);
    expect(find.text('Slides'), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Fused (beta)'), findsOneWidget);

    // And the menu sits above the icon rather than on top of it. Material
    // anchors it to the button's top edge and, finding no room below in a bar
    // at the foot of the video, slides it up over the control that opened it.
    final Rect button = tester.getRect(find.byTooltip('Camera angle'));
    final Rect lastItem = tester.getRect(find.text('Fused (beta)'));
    expect(lastItem.bottom, lessThanOrEqualTo(button.top));

    // ...and is centred on the icon rather than hanging off one side of it.
    // Material would otherwise right-align it, because the icon sits nearer
    // the right edge of the screen than the left.
    final Rect menu = tester.getRect(
      find
          .ancestor(
            of: find.text('Fused (beta)'),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(menu.center.dx, closeTo(button.center.dx, 1));
  });

  testWidgets('a landscape window alone does not hide the lecture list', (
    WidgetTester tester,
  ) async {
    // 800x600 is landscape. It used to be enough to throw the page into
    // fullscreen on its own, which meant a phone rotating on a desk did too.
    VideoPlayerPlatform.instance = _FailingVideoPlatform();

    await pumpApp(tester, fakeTumLive());
    await tester.tap(find.text('Analysis for Informatics'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('21.10.2025'));
    await tester.pumpAndSettle();

    expect(find.byType(LecturePlayer), findsOneWidget);
    expect(find.text('More in this course'), findsOneWidget);
  });

  testWidgets('the fullscreen button is what hides the lecture list', (
    WidgetTester tester,
  ) async {
    final _WorkingVideoPlatform video = _WorkingVideoPlatform();
    VideoPlayerPlatform.instance = video;

    await pumpApp(tester, fakeTumLive());
    await tester.tap(find.text('Analysis for Informatics'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('21.10.2025'));
    // Not pumpAndSettle: this platform loads successfully, so the player sits
    // on a spinner until the video reports in — and a spinner never settles.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // The chrome only exists once the video is up, and so does the button.
    // Explicit pumps, not pumpAndSettle: a playing video polls its position
    // every 500ms, so there is always another frame coming and nothing ever
    // settles.
    video.completeInitialization();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('More in this course'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('fullscreen-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('More in this course'), findsNothing);
    // Still the same controller: the layout change must not restart the video.
    expect(video.createCount, 1);

    // And back again.
    await tester.tap(find.byKey(const ValueKey('fullscreen-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('More in this course'), findsOneWidget);
    expect(video.createCount, 1);
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
/// A platform that comes up successfully, so the player draws its control bar
/// and the fullscreen button can be pressed. The picture itself is a blank box.
class _WorkingVideoPlatform extends VideoPlayerPlatform {
  final StreamController<VideoEvent> _events =
      StreamController<VideoEvent>.broadcast();

  @override
  Future<void> init() async {}

  /// Counts controllers created, so a test can prove the video was not torn
  /// down and rebuilt behind a layout change.
  int createCount = 0;

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    createCount++;
    return 1;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events.stream;

  @override
  Future<void> dispose(int playerId) async => _events.close();

  @override
  Future<void> play(int playerId) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.expand();

  void completeInitialization() => _events.add(
    VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(minutes: 3),
      size: const Size(1920, 1080),
      rotationCorrection: 0,
    ),
  );
}

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
