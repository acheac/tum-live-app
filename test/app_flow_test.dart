// Walks the app the way a student does — home screen, into a course, into the
// player — with a fake TUM-Live behind it.
//
// This is the test that would have caught a wrong JSON field name in a screen,
// which the unit tests in api_test.dart cannot: they check that parsing works,
// this checks that the parsed values reach the pixels.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
http.Client fakeTumLive({
  bool noRecording = false,
  String courseName = 'Analysis for Informatics',
  int publicCourses = 1,
  bool coursePinned = false,
  bool failPin = false,
  List<bool>? pinCalls,
  List<String> pinnedSlugs = const <String>[],
  List<int> liveCourseIds = const <int>[],
}) {
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

  Map<String, dynamic> courseJson(String slug, String name, int id) =>
      <String, dynamic>{
        'id': id,
        'name': name,
        'slug': slug,
        'semester': <String, dynamic>{'teachingTerm': 'W', 'year': 2025},
        'visibility': 'public',
        'pinned': true,
        'lastRecording': lecture(102, '2025-10-21'),
      };

  return MockClient((http.Request request) async {
    final String path = request.url.path;
    Map<String, dynamic>? body;

    // Enough of the auth flow that a test can sign in by seeding a cookie.
    if (path.endsWith('/auth/token')) {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'access_token': 'access',
          'token_type': 'Bearer',
          'expires_in': 3600,
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }
    if (path.endsWith('/users/me')) {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'user': <String, dynamic>{'id': 7, 'name': 'Ada Lovelace'},
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }
    // POST /courses/{id}/pin — recorded so a test can assert what was asked
    // for, and optionally failed so the revert path is reachable.
    if (path.endsWith('/pin')) {
      final Map<String, dynamic> sent =
          jsonDecode(request.body) as Map<String, dynamic>;
      pinCalls?.add(sent['pin'] as bool);
      if (failPin) return http.Response('{"message":"nope"}', 500);
      return http.Response('{}', 200, headers: <String, String>{
        'content-type': 'application/json',
      });
    }
    if (path.endsWith('/courses/pinned')) {
      body = <String, dynamic>{
        'courses': <dynamic>[
          for (int i = 0; i < pinnedSlugs.length; i++)
            courseJson(pinnedSlugs[i], 'Pinned ${pinnedSlugs[i]}', 500 + i),
        ],
      };
      return http.Response(
        jsonEncode(body),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }

    if (path.endsWith('/semesters')) {
      body = <String, dynamic>{
        'current': <String, dynamic>{'teachingTerm': 'W', 'year': 2025},
        'semesters': <dynamic>[
          <String, dynamic>{'teachingTerm': 'W', 'year': 2025},
          <String, dynamic>{'teachingTerm': 'S', 'year': 2025},
          // The real list runs to sixteen terms and ends with these two, which
          // the server has always sent and which have never had a course.
          for (int y = 2024; y >= 2019; y--) ...<dynamic>[
            <String, dynamic>{'teachingTerm': 'W', 'year': y},
            <String, dynamic>{'teachingTerm': 'S', 'year': y},
          ],
          <String, dynamic>{'teachingTerm': 'S', 'year': 1970},
          <String, dynamic>{'teachingTerm': 'W', 'year': 23},
        ],
      };
    } else if (path.endsWith('/courses/live')) {
      // One live stream per id. The ids matter: the home screen keeps only the
      // ones that are also enrolled or pinned.
      body = <String, dynamic>{
        'liveCourses': <dynamic>[
          for (final int id in liveCourseIds)
            <String, dynamic>{
              'course': <String, dynamic>{
                'id': id,
                'name': 'Live course $id',
                'slug': 'live-$id',
                'semester': <String, dynamic>{
                  'teachingTerm': 'W',
                  'year': 2025,
                },
                'visibility': 'public',
              },
              'stream': <String, dynamic>{
                'id': 9000 + id,
                'name': 'Live lecture',
                'courseId': id,
                'liveNow': true,
              },
            },
        ],
      };
    } else if (path.endsWith('/courses/analysis')) {
      body = <String, dynamic>{
        'course': <String, dynamic>{
          'id': 42,
          'name': courseName,
          'slug': 'analysis',
          'semester': <String, dynamic>{'teachingTerm': 'W', 'year': 2025},
          'visibility': 'public',
          'pinned': coursePinned,
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
          'name': courseName,
          'slug': 'analysis',
        },
        'stream': noRecording ? lectureWithoutVideo(id) : lecture(id, '2025-10-21'),
      };
    } else if (path.endsWith('/courses')) {
      body = <String, dynamic>{
        'courses': <dynamic>[
          <String, dynamic>{
            'id': 42,
            'name': courseName,
            'slug': 'analysis',
            'semester': <String, dynamic>{'teachingTerm': 'W', 'year': 2025},
            'visibility': 'public',
            'lastRecording': lecture(102, '2025-10-21'),
          },
          // Filler, so a test can ask for more than one page of them. Named by
          // index rather than by the real course, which stays first.
          for (int i = 1; i < publicCourses; i++)
            <String, dynamic>{
              'id': 1000 + i,
              'name': 'Filler course $i',
              'slug': 'filler-$i',
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
/// A surface tall enough that a whole group of course tiles is built.
///
/// `SliverList.builder` only builds what is on screen plus a small cache, and
/// `widgetList` only finds what was built — so on the default 800x600 surface
/// the fifth tile of a group is simply absent and counting them undercounts.
void useTallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Sizes the test surface like the phone this was reported on.
///
/// The default 800x600 surface is more than twice a phone's width, so a title
/// that wraps or truncates on the device fits on one comfortable line in a test
/// and every assertion about it passes vacuously. Both title tests below are
/// only meaningful at a real phone's width.
void useNarrowPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2352);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<AuthController> pumpApp(
  WidgetTester tester,
  http.Client client, {
  bool signedIn = false,
}) async {
  final MemoryCredentialStore store = MemoryCredentialStore();
  // A stored cookie is all restore() needs to come back signed in, and
  // fakeTumLive answers the two endpoints it checks it against.
  if (signedIn) await store.writeSessionCookie('cookie-value');
  final AuthController auth = AuthController(
    source: CookieTokenSource(store: store, client: client),
    client: client,
  );
  // Without a stored cookie this settles straight into signedOut, which is the
  // state a first-time user sees.
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

    // A PopupMenuButton, not a DropdownButton: the same menu carries the
    // pinned courses, and a dropdown's label is its selection, so picking a
    // course would leave its name where the semester belongs.
    await tester.tap(find.byKey(const ValueKey<String>('semester-menu')));
    await tester.pumpAndSettle();

    expect(find.text('SS 2025'), findsWidgets);
  });

  testWidgets('the picker leaves out the placeholder semesters',
      (WidgetTester tester) async {
    // `/semesters` ends with `S 1970` and `W 23` — an epoch default and a
    // year that never parsed. Both render as ordinary terms at the bottom of
    // the picker and neither has ever had a course.
    await pumpApp(tester, fakeTumLive());

    await tester.tap(find.byKey(const ValueKey<String>('semester-menu')));
    await tester.pumpAndSettle();

    expect(find.text('SS 1970'), findsNothing);
    expect(find.text('WS 23'), findsNothing);
    // The real ones are still all there.
    expect(find.text('SS 2019'), findsWidgets);
  });

  testWidgets('the semester menu stays on screen instead of being moved',
      (WidgetTester tester) async {
    // Sixteen terms is taller than a phone, and a menu that cannot fit under
    // its button gets repositioned somewhere it does fit — it opens shifted up
    // the screen, away from what was tapped. Bounded, it scrolls instead.
    useNarrowPhone(tester);
    await pumpApp(tester, fakeTumLive());

    final Rect button = tester.getRect(
      find.byKey(const ValueKey<String>('semester-menu')),
    );
    await tester.tap(find.byKey(const ValueKey<String>('semester-menu')));
    await tester.pumpAndSettle();

    // The menu's own scroll view: its box is the menu's box.
    final Rect menu = tester.getRect(
      find.byType(SingleChildScrollView).last,
    );
    final Size screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(menu.height, lessThanOrEqualTo(screen.height / 2 + 1));
    expect(menu.bottom, lessThanOrEqualTo(screen.height));
    // And it is still anchored under the button that opened it.
    expect(menu.top, greaterThanOrEqualTo(button.top));
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

  testWidgets('the header has room for a wrapped course name',
      (WidgetTester tester) async {
    // A real TUM course name, and the one this page was reported on. AppBar
    // wraps its title in a DefaultTextStyle with `softWrap: false, overflow:
    // ellipsis`, so a plain Text renders one clipped line however tall the bar
    // is — "Fachschaftsvollversamml…" — while the lecture card below wraps the
    // same string fine.
    //
    // How many lines the name actually needs is not assertable here: the test
    // font draws every glyph one em wide, so text measures about twice its
    // width under Roboto and any line count would describe the test font
    // rather than the phone. What is font-independent is that the bar is tall
    // enough for the lines it permits — a title that wraps inside a 56dp bar
    // is clipped rather than ellipsized, which reads as a rendering bug.
    const String name =
        'Fachschaftsvollversammlung - School of Computation, '
        'Information and Technology';
    useNarrowPhone(tester);
    await pumpApp(tester, fakeTumLive(courseName: name));

    await tester.tap(find.text(name).first);
    await tester.pumpAndSettle();

    final Finder title = find.descendant(
      of: find.byType(AppBar),
      matching: find.text(name),
    );
    expect(tester.widget<Text>(title).maxLines, 3);
    expect(tester.widget<Text>(title).softWrap, isTrue);
    expect(
      tester.getRect(title).height,
      lessThanOrEqualTo(tester.getRect(find.byType(AppBar)).height),
    );
  });

  testWidgets('the header title is a size down from the AppBar default',
      (WidgetTester tester) async {
    // At AppBar's own titleLarge, "Fachschaftsvollversammlung" is wider than
    // the bar and Flutter's last resort is to split it: the header read
    // "Fachschaftsvollversammlun / g - School of Computation…". The smaller
    // size is what fits that word on one line, so the rest can wrap at spaces.
    // Asserted as a size relative to titleLarge because the exact width the
    // word takes depends on the font, which differs under test.
    const String name = 'Fachschaftsvollversammlung Informatik';
    useNarrowPhone(tester);
    await pumpApp(tester, fakeTumLive(courseName: name));

    await tester.tap(find.text(name).first);
    await tester.pumpAndSettle();

    final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: find.byType(AppBar), matching: find.text(name)),
    );
    final TextTheme textTheme = Theme.of(
      tester.element(find.byType(AppBar)),
    ).textTheme;
    expect(
      paragraph.text.style?.fontSize,
      lessThan(textTheme.titleLarge!.fontSize!),
    );
  });

  testWidgets('leaving the player on a phone does not unlock rotation',
      (WidgetTester tester) async {
    // dispose used to hand back DeviceOrientation.values unconditionally, to
    // undo the player's own landscape pin. On a phone that is not a restore
    // but a change: the course list the user lands back on had rotation off,
    // and would come back with it on.
    final List<List<String>> requested = <List<String>>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'SystemChrome.setPreferredOrientations') {
          requested.add(List<String>.from(call.arguments as List<dynamic>));
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    useNarrowPhone(tester);
    await pumpApp(tester, fakeTumLive());
    await tester.tap(find.text('Analysis for Informatics'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('21.10.2025'));
    await tester.pumpAndSettle();

    requested.clear();
    // Not tester.pageBack(): the player has no AppBar to hold a default back
    // button, so it carries its own.
    await tester.tap(find.byKey(const ValueKey<String>('player-back-button')));
    await tester.pumpAndSettle();

    // Whatever it asked for on the way out, it was not every orientation.
    expect(requested, isNotEmpty);
    for (final List<String> call in requested) {
      expect(call, <String>['DeviceOrientation.portraitUp']);
    }
  });

  testWidgets('the search field filters the course list',
      (WidgetTester tester) async {
    await pumpApp(tester, fakeTumLive());
    expect(find.text('Analysis for Informatics'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey<String>('course-search')),
      'analysis',
    );
    await tester.pumpAndSettle();
    expect(find.text('Analysis for Informatics'), findsOneWidget);

    // A query nothing matches replaces the sections rather than leaving them
    // looking empty for no stated reason.
    await tester.enterText(
      find.byKey(const ValueKey<String>('course-search')),
      'quantum',
    );
    await tester.pumpAndSettle();
    expect(find.text('Analysis for Informatics'), findsNothing);
    expect(find.textContaining('matches'), findsOneWidget);

    // Clearing brings everything back, and takes the clear button with it.
    await tester.tap(
      find.byKey(const ValueKey<String>('course-search-clear')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Analysis for Informatics'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('course-search-clear')),
      findsNothing,
    );
  });

  testWidgets('searching without an umlaut still finds the course',
      (WidgetTester tester) async {
    // The reason foldForSearch exists, exercised through the real field: an
    // English keyboard cannot type the ü that the course name has.
    await pumpApp(
      tester,
      fakeTumLive(courseName: 'Einführung in die Softwaretechnik'),
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('course-search')),
      'einfuhrung',
    );
    await tester.pumpAndSettle();

    expect(find.text('Einführung in die Softwaretechnik'), findsWidgets);
  });

  testWidgets('the public list shows five at a time, and rotates',
      (WidgetTester tester) async {
    // 12 courses rotate 5, 5, 2 and then come back round. The order is
    // shuffled at load, so the assertions are about counts and disjointness
    // rather than which course lands where.
    useTallScreen(tester);
    await pumpApp(tester, fakeTumLive(publicCourses: 12));

    Set<String> shown() => tester
        .widgetList<Text>(find.textContaining(RegExp('Filler course|Analysis')))
        .map((Text t) => t.data!)
        .toSet();

    final Finder rotate = find.byKey(const ValueKey<String>('public-rotate'));
    expect(rotate, findsOneWidget);
    expect(find.text('1–5 of 12'), findsOneWidget);
    final Set<String> first = shown();
    expect(first.length, 5);

    await tester.tap(rotate);
    await tester.pumpAndSettle();
    expect(find.text('6–10 of 12'), findsOneWidget);
    final Set<String> second = shown();
    expect(second.length, 5);
    // "Another five" has to mean five you have not just seen.
    expect(first.intersection(second), isEmpty);

    // The remainder is short rather than padded from the top again.
    await tester.tap(rotate);
    await tester.pumpAndSettle();
    expect(find.text('11–12 of 12'), findsOneWidget);
    expect(shown().length, 2);

    // And then round to the start, so the button never dead-ends.
    await tester.tap(rotate);
    await tester.pumpAndSettle();
    expect(find.text('1–5 of 12'), findsOneWidget);
    expect(shown(), first);
  });

  testWidgets('a semester with five or fewer has no rotate button',
      (WidgetTester tester) async {
    // Nothing to rotate to, so offering it would be a button that changes
    // nothing.
    await pumpApp(tester, fakeTumLive(publicCourses: 5));
    expect(find.byKey(const ValueKey<String>('public-rotate')), findsNothing);
  });

  testWidgets('searching is never capped at five',
      (WidgetTester tester) async {
    // The cap is for browsing. Hiding search matches behind a rotate button is
    // the one thing search must not do.
    useTallScreen(tester);
    await pumpApp(tester, fakeTumLive(publicCourses: 12));
    expect(find.byKey(const ValueKey<String>('public-rotate')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey<String>('course-search')),
      'filler',
    );
    await tester.pumpAndSettle();

    // All 11 fillers, not 5, and the button is gone while the query stands.
    expect(find.textContaining('Filler course'), findsNWidgets(11));
    expect(find.byKey(const ValueKey<String>('public-rotate')), findsNothing);
  });

  group('pinning', () {
    testWidgets('the course page pins, and the icon fills in',
        (WidgetTester tester) async {
      final List<bool> calls = <bool>[];
      await pumpApp(
        tester,
        fakeTumLive(pinCalls: calls),
        signedIn: true,
      );
      await tester.tap(find.text('Analysis for Informatics').first);
      await tester.pumpAndSettle();

      final Finder pin = find.byKey(const ValueKey<String>('pin-button'));
      expect(pin, findsOneWidget);
      // Outlined until it is pinned.
      expect(
        tester.widget<Icon>(find.descendant(of: pin, matching: find.byType(Icon))).icon,
        Icons.push_pin_outlined,
      );

      await tester.tap(pin);
      await tester.pumpAndSettle();

      expect(calls, <bool>[true]);
      expect(
        tester.widget<Icon>(find.descendant(of: pin, matching: find.byType(Icon))).icon,
        Icons.push_pin,
      );
    });

    testWidgets('an already pinned course unpins',
        (WidgetTester tester) async {
      final List<bool> calls = <bool>[];
      await pumpApp(
        tester,
        fakeTumLive(coursePinned: true, pinCalls: calls),
        signedIn: true,
      );
      await tester.tap(find.text('Analysis for Informatics').first);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey<String>('pin-button')));
      await tester.pumpAndSettle();
      expect(calls, <bool>[false]);
    });

    testWidgets('a failed pin puts the icon back and says so',
        (WidgetTester tester) async {
      // Every other failure in this app is silent, but the user watched this
      // icon change — leaving it filled would have the UI claiming a pin the
      // server refused.
      await pumpApp(
        tester,
        fakeTumLive(failPin: true),
        signedIn: true,
      );
      await tester.tap(find.text('Analysis for Informatics').first);
      await tester.pumpAndSettle();

      final Finder pin = find.byKey(const ValueKey<String>('pin-button'));
      await tester.tap(pin);
      await tester.pumpAndSettle();

      expect(
        tester.widget<Icon>(find.descendant(of: pin, matching: find.byType(Icon))).icon,
        Icons.push_pin_outlined,
      );
      expect(find.textContaining('Could not pin'), findsOneWidget);
    });

    testWidgets('signed out there is no pin button at all',
        (WidgetTester tester) async {
      // Pinning is per-account and the endpoint needs a token, so a button
      // here could only ever fail.
      await pumpApp(tester, fakeTumLive());
      await tester.tap(find.text('Analysis for Informatics').first);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('pin-button')), findsNothing);
    });

    testWidgets('the player page carries the pin below the picture',
        (WidgetTester tester) async {
      final List<bool> calls = <bool>[];
      await pumpApp(tester, fakeTumLive(pinCalls: calls), signedIn: true);
      await tester.tap(find.text('Analysis for Informatics').first);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('21.10.2025'));
      await tester.pumpAndSettle();

      final Finder pin = find.byKey(const ValueKey<String>('pin-button'));
      expect(pin, findsOneWidget);
      // Below the video, which is what "under the fullscreen button" means.
      expect(
        tester.getRect(pin).top,
        greaterThan(tester.getRect(find.byType(LecturePlayer)).bottom - 1),
      );

      await tester.tap(pin);
      await tester.pumpAndSettle();
      expect(calls, <bool>[true]);
    });

    testWidgets('the menu switches My courses for the pinned ones',
        (WidgetTester tester) async {
      await pumpApp(
        tester,
        fakeTumLive(pinnedSlugs: const <String>['algebra']),
        signedIn: true,
      );

      // Not on the page to begin with, and no count beside the semester:
      // the pinned list is a view now, not a badge.
      expect(find.text('Pinned algebra'), findsNothing);
      expect(find.text('My courses'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('semester-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pinned courses'));
      await tester.pumpAndSettle();

      // My courses gave way to the pinned ones.
      expect(find.text('Pinned courses'), findsOneWidget);
      expect(find.text('My courses'), findsNothing);
      expect(find.text('Pinned algebra'), findsOneWidget);
      // And the rest of the page is out of the way, so the search field below
      // means only what this view shows.
      expect(find.text('Public courses'), findsNothing);
    });

    testWidgets('the pinned view is a toggle, not a one-way door',
        (WidgetTester tester) async {
      await pumpApp(
        tester,
        fakeTumLive(pinnedSlugs: const <String>['algebra']),
        signedIn: true,
      );

      Future<void> openMenu() async {
        await tester.tap(find.byKey(const ValueKey<String>('semester-menu')));
        await tester.pumpAndSettle();
      }

      await openMenu();
      await tester.tap(find.text('Pinned courses'));
      await tester.pumpAndSettle();

      // The same entry now offers the way back.
      await openMenu();
      await tester.tap(find.text('My courses').last);
      await tester.pumpAndSettle();

      expect(find.text('My courses'), findsOneWidget);
      expect(find.text('Public courses'), findsOneWidget);
    });

    testWidgets('picking a semester leaves the pinned view',
        (WidgetTester tester) async {
      // /courses/pinned takes no semester, so staying put would swallow the
      // choice — the label would change and the list would not.
      await pumpApp(
        tester,
        fakeTumLive(pinnedSlugs: const <String>['algebra']),
        signedIn: true,
      );

      await tester.tap(find.byKey(const ValueKey<String>('semester-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pinned courses'));
      await tester.pumpAndSettle();
      expect(find.text('Pinned courses'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('semester-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SS 2025').last);
      await tester.pumpAndSettle();

      expect(find.text('SS 2025'), findsOneWidget);
      expect(find.text('Pinned courses'), findsNothing);
      expect(find.text('My courses'), findsOneWidget);
    });

    testWidgets('switching views clears the search field',
        (WidgetTester tester) async {
      await pumpApp(
        tester,
        fakeTumLive(pinnedSlugs: const <String>['algebra'], publicCourses: 12),
        signedIn: true,
      );

      final Finder field = find.byKey(const ValueKey<String>('course-search'));
      await tester.enterText(field, 'filler');
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, 'filler');

      await tester.tap(find.byKey(const ValueKey<String>('semester-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pinned courses'));
      await tester.pumpAndSettle();

      // Empty field, and the pinned course visible rather than filtered away
      // by a query aimed at a list this view does not show.
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      expect(find.text('Pinned algebra'), findsOneWidget);
      expect(find.text('No pinned courses match.'), findsNothing);
    });

    testWidgets('leaving the pinned view clears it too',
        (WidgetTester tester) async {
      await pumpApp(
        tester,
        fakeTumLive(pinnedSlugs: const <String>['algebra']),
        signedIn: true,
      );

      await tester.tap(find.byKey(const ValueKey<String>('semester-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pinned courses'));
      await tester.pumpAndSettle();

      final Finder field = find.byKey(const ValueKey<String>('course-search'));
      await tester.enterText(field, 'algebra');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey<String>('semester-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('My courses').last);
      await tester.pumpAndSettle();

      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      expect(find.text('Public courses'), findsOneWidget);
    });

    testWidgets('search inside the pinned view searches only pinned courses',
        (WidgetTester tester) async {
      await pumpApp(
        tester,
        fakeTumLive(pinnedSlugs: const <String>['algebra'], publicCourses: 12),
        signedIn: true,
      );

      await tester.tap(find.byKey(const ValueKey<String>('semester-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pinned courses'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey<String>('course-search')),
        'filler',
      );
      await tester.pumpAndSettle();

      // "Filler course N" exists, but only in the public list this view hides.
      // A search from in here must not drag it back in.
      expect(find.textContaining('Filler course'), findsNothing);
      expect(find.text('No pinned courses match.'), findsOneWidget);
    });

    testWidgets('an empty pinned view says how to fill it',
        (WidgetTester tester) async {
      await pumpApp(tester, fakeTumLive(), signedIn: true);

      await tester.tap(find.byKey(const ValueKey<String>('semester-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pinned courses'));
      await tester.pumpAndSettle();

      // Offered even with nothing pinned, because this is where the empty
      // state gets explained.
      expect(find.textContaining('Open a course and tap the pin'), findsOneWidget);
    });

    testWidgets('a pinned course is marked in the course list',
        (WidgetTester tester) async {
      // The list the pin is drawn from is the pinned list, not Course.pinned,
      // which the server only sets on some endpoints.
      await pumpApp(
        tester,
        fakeTumLive(pinnedSlugs: const <String>['algebra']),
        signedIn: true,
      );

      await tester.tap(find.byKey(const ValueKey<String>('semester-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pinned courses'));
      await tester.pumpAndSettle();

      final Finder tile = find.ancestor(
        of: find.text('Pinned algebra'),
        matching: find.byType(ListTile),
      );
      expect(
        find.descendant(of: tile, matching: find.byIcon(Icons.push_pin)),
        findsOneWidget,
      );
    });
  });

  testWidgets('Live now keeps only the signed-in user\'s own courses',
      (WidgetTester tester) async {
    // /courses/live is every stream on TUM-Live, and this section sits above
    // everything else. Course 500 is the pinned one the fake serves; 999 is
    // somebody else's lecture.
    await pumpApp(
      tester,
      fakeTumLive(
        pinnedSlugs: const <String>['algebra'],
        liveCourseIds: const <int>[500, 999],
      ),
      signedIn: true,
    );

    expect(find.text('Live now'), findsOneWidget);
    expect(find.text('Live course 500'), findsOneWidget);
    expect(find.text('Live course 999'), findsNothing);
  });

  testWidgets('signed out, Live now is not narrowed to nothing',
      (WidgetTester tester) async {
    // There is no "my courses" to narrow to, and anything a signed-out user
    // can see live is public anyway — so filtering here would only empty the
    // section.
    await pumpApp(tester, fakeTumLive(liveCourseIds: const <int>[500, 999]));

    expect(find.text('Live course 500'), findsOneWidget);
    expect(find.text('Live course 999'), findsOneWidget);
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
