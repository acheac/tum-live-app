// Widget tests for the TUMLive player.
//
// The real video_player plugin is unavailable under `flutter test` (no platform
// implementation is registered), so we inject a fake VideoPlayerPlatform and use
// it to drive the three UI states: loading, playing, and failed.

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'package:tumlive_player/src/player/lecture_player.dart';

/// Fake platform implementation: never touches the network. Each test decides
/// whether initialization succeeds or fails.
class _FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  _FakeVideoPlayerPlatform({
    this.duration = const Duration(minutes: 3, seconds: 5),
    this.size = const Size(1920, 1080),
    this.failOnCreate = false,
  });

  /// Duration reported once initialized.
  final Duration duration;

  /// Video size reported once initialized; this drives the AspectRatio.
  final Size size;

  /// When true, simulate a load failure (network or sandbox permission error).
  /// Not final: the retry test needs to fail first and then succeed.
  bool failOnCreate;

  /// A fresh event stream per create(), mimicking a brand new controller.
  StreamController<VideoEvent> _events =
      StreamController<VideoEvent>.broadcast();

  /// Records which methods were called, so tests can assert that play/pause
  /// actually reached the platform layer.
  final List<String> calls = <String>[];

  Duration _position = Duration.zero;
  int _playerId = 0;

  /// Pushes an event to the controller by hand.
  void emit(VideoEvent event) => _events.add(event);

  /// Emits the initialized event so the `initialize()` future completes.
  void completeInitialization() => emit(VideoEvent(
        eventType: VideoEventType.initialized,
        duration: duration,
        size: size,
        rotationCorrection: 0,
      ));

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    calls.add('create');
    if (failOnCreate) {
      throw PlatformException(code: 'VideoError', message: 'network denied');
    }
    if (_events.isClosed) {
      _events = StreamController<VideoEvent>.broadcast();
    }
    _position = Duration.zero;
    return ++_playerId;
  }

  @override
  Future<void> dispose(int playerId) async {
    calls.add('dispose');
    await _events.close();
  }

  /// Lets the next create() succeed, for the retry test.
  void recover() {
    failOnCreate = false;
    if (_events.isClosed) {
      _events = StreamController<VideoEvent>.broadcast();
    }
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events.stream;

  @override
  Future<void> play(int playerId) async {
    calls.add('play');
    emit(VideoEvent(eventType: VideoEventType.isPlayingStateUpdate, isPlaying: true));
  }

  @override
  Future<void> pause(int playerId) async {
    calls.add('pause');
    emit(VideoEvent(eventType: VideoEventType.isPlayingStateUpdate, isPlaying: false));
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  /// When set, seekTo parks until the test completes it. Lets a test observe
  /// the UI while a seek is still in flight.
  Completer<void>? seekGate;

  /// When true, getPosition keeps reporting the pre-seek position, simulating
  /// a poll that was already in flight when the seek landed.
  bool reportStalePosition = false;

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    calls.add('seekTo');
    if (seekGate != null) await seekGate!.future;
    _position = position;
  }

  /// Where the last seek landed.
  Duration get seekedTo => _position;

  @override
  Future<Duration> getPosition(int playerId) async =>
      reportStalePosition ? Duration.zero : _position;

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.expand(key: ValueKey('fake-video-view'));
}

/// Which part of the player to point at.
enum PlayerZone { top, bottom }

/// The one mouse pointer shared by all hoverAt calls within a test. Adding a
/// second pointer would leave the first parked where it was, so the widget
/// would still think the mouse is down there.
TestGesture? _mouse;

/// Moves the mouse pointer into the given part of the player surface.
Future<void> hoverAt(WidgetTester tester, PlayerZone zone) async {
  final Rect surface =
      tester.getRect(find.byKey(const ValueKey('player-surface')));
  final Offset target = zone == PlayerZone.bottom
      ? Offset(surface.center.dx, surface.bottom - 8)
      : Offset(surface.center.dx, surface.top + 8);

  if (_mouse == null) {
    final TestGesture gesture =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    _mouse = gesture;
    addTearDown(() async {
      await gesture.removePointer();
      _mouse = null;
    });
  }
  await _mouse!.moveTo(target);
  await tester.pumpAndSettle();
}

/// Reads the control bar's current opacity (1 = shown, 0 = hidden).
double controlBarOpacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(find.byKey(const ValueKey('control-bar')))
    .opacity;

void main() {
  late _FakeVideoPlayerPlatform fake;

  /// Installs the fake platform, pumps the player, and lets create() settle.
  ///
  /// Pumps [LecturePlayer] rather than the whole app: the player takes a plain
  /// URL and knows nothing about the API, so these tests need no fake HTTP
  /// client. Resolving a lecture id into a URL is PlayerPage's job and is
  /// tested separately.
  Future<void> pumpApp(WidgetTester tester) async {
    VideoPlayerPlatform.instance = fake;
    await tester.pumpWidget(
      const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: LecturePlayer(
          videoUrl: 'https://example.invalid/playlist.m3u8',
          title: 'TUMLive Player',
        ),
      ),
    );
    await tester.pump(); // let the createWithOptions future land
  }

  group('loads successfully', () {
    setUp(() => fake = _FakeVideoPlayerPlatform());

    testWidgets('shows a spinner and no player before initialization completes', (WidgetTester tester) async {
      await pumpApp(tester);

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(VideoPlayer), findsNothing);
      expect(find.textContaining('Could not load the video'), findsNothing);
    });

    testWidgets('shows the player and seek bar once initialized', (WidgetTester tester) async {
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(VideoPlayer), findsOneWidget);
      expect(find.byKey(const ValueKey('seek-bar')), findsOneWidget);

      // A 1920x1080 video should give a 16:9 AspectRatio.
      final aspectRatio = tester.widget<AspectRatio>(
        find.ancestor(
          of: find.byType(VideoPlayer),
          matching: find.byType(AspectRatio),
        ),
      );
      expect(aspectRatio.aspectRatio, closeTo(16 / 9, 0.001));
    });

    testWidgets('AspectRatio follows the size reported by the platform', (WidgetTester tester) async {
      fake = _FakeVideoPlayerPlatform(size: const Size(640, 480));
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();

      final aspectRatio = tester.widget<AspectRatio>(
        find.ancestor(
          of: find.byType(VideoPlayer),
          matching: find.byType(AspectRatio),
        ),
      );
      expect(aspectRatio.aspectRatio, closeTo(4 / 3, 0.001));
    });

    testWidgets('shows position and duration as mm:ss', (WidgetTester tester) async {
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();

      expect(find.text('00:00 / 03:05'), findsOneWidget);
    });

    testWidgets('durations past an hour render as h:mm:ss', (WidgetTester tester) async {
      fake = _FakeVideoPlayerPlatform(
        duration: const Duration(hours: 1, minutes: 32, seconds: 7),
      );
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();

      expect(find.text('00:00 / 1:32:07'), findsOneWidget);
    });

    testWidgets('autoplays once initialized and shows the pause icon', (WidgetTester tester) async {
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();

      expect(fake.calls, contains('play'));
      expect(find.byIcon(Icons.pause), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsNothing);
    });

    testWidgets('the play button pauses and resumes playback', (WidgetTester tester) async {
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();

      // Playing: tap to pause.
      await tester.tap(find.byKey(const ValueKey('play-pause-button')));
      await tester.pumpAndSettle();
      expect(fake.calls, contains('pause'));
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);

      // Paused: tap to resume.
      fake.calls.clear();
      await tester.tap(find.byKey(const ValueKey('play-pause-button')));
      await tester.pumpAndSettle();
      expect(fake.calls, contains('play'));
      expect(find.byIcon(Icons.pause), findsOneWidget);
    });
  });

  group('control bar (Bilibili style)', () {
    setUp(() => fake = _FakeVideoPlayerPlatform());

    testWidgets('the bar floats over the picture instead of pushing it up', (WidgetTester tester) async {
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();

      // Seek bar and picture share a Stack, so it overlays rather than stacks below.
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey('seek-bar')),
          matching: find.byType(Stack),
        ),
        findsWidgets,
      );
      expect(controlBarOpacity(tester), 1);
    });

    testWidgets('the bar auto-hides after 3 idle seconds while playing', (WidgetTester tester) async {
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();
      expect(controlBarOpacity(tester), 1);

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(controlBarOpacity(tester), 0);
    });

    testWidgets('moving the mouse to the bottom strip brings the bar back', (WidgetTester tester) async {
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(controlBarOpacity(tester), 0);

      await hoverAt(tester, PlayerZone.bottom);
      expect(controlBarOpacity(tester), 1);
    });

    testWidgets('moving the mouse across the upper area leaves the bar hidden', (WidgetTester tester) async {
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(controlBarOpacity(tester), 0);

      await hoverAt(tester, PlayerZone.top);
      expect(controlBarOpacity(tester), 0);
    });

    testWidgets('leaving the bottom strip lets the bar fade away again', (WidgetTester tester) async {
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();

      await hoverAt(tester, PlayerZone.bottom);
      expect(controlBarOpacity(tester), 1);

      await hoverAt(tester, PlayerZone.top);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(controlBarOpacity(tester), 0);
    });

    testWidgets('the bar stays visible while paused', (WidgetTester tester) async {
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('play-pause-button')));
      await tester.pumpAndSettle();

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(controlBarOpacity(tester), 1);
    });

    testWidgets('a hidden bar cannot be clicked (IgnorePointer is on)',
        (WidgetTester tester) async {
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      final ignore = tester.widget<IgnorePointer>(
        find.descendant(
          of: find.byKey(const ValueKey('control-bar')),
          matching: find.byType(IgnorePointer),
        ),
      );
      expect(ignore.ignoring, isTrue);
    });
  });

  group('seek handle', () {
    setUp(() => fake = _FakeVideoPlayerPlatform());

    testWidgets('dragging the handle seeks the video', (WidgetTester tester) async {
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();

      final Finder bar = find.byKey(const ValueKey('seek-bar'));
      final Rect rect = tester.getRect(bar);

      // Grab at the far left (position 0) and drag to roughly the middle.
      final TestGesture drag =
          await tester.startGesture(Offset(rect.left + 26, rect.center.dy));
      await tester.pump();
      await drag.moveTo(Offset(rect.center.dx, rect.center.dy));
      await tester.pump();

      // Nothing is sought until release, so the video is not thrashed mid-drag.
      expect(fake.calls, isNot(contains('seekTo')));

      await drag.up();
      await tester.pumpAndSettle();

      expect(fake.calls, contains('seekTo'));
      // 3m05s total, dropped near the middle.
      expect(fake.seekedTo.inSeconds, greaterThan(60));
      expect(fake.seekedTo.inSeconds, lessThan(125));
    });

    testWidgets('the clock follows the handle while dragging', (WidgetTester tester) async {
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();
      expect(find.text('00:00 / 03:05'), findsOneWidget);

      final Rect rect = tester.getRect(find.byKey(const ValueKey('seek-bar')));
      final TestGesture drag =
          await tester.startGesture(Offset(rect.left + 26, rect.center.dy));
      await tester.pump();
      await drag.moveTo(Offset(rect.center.dx, rect.center.dy));
      await tester.pumpAndSettle();

      // Still 03:05 total, but the left half now shows the drag target.
      expect(find.text('00:00 / 03:05'), findsNothing);
      expect(find.textContaining('/ 03:05'), findsOneWidget);

      await drag.up();
      await tester.pumpAndSettle();
    });

    testWidgets('the bar will not auto-hide mid-drag', (WidgetTester tester) async {
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();

      final Rect rect = tester.getRect(find.byKey(const ValueKey('seek-bar')));
      final TestGesture drag =
          await tester.startGesture(Offset(rect.left + 26, rect.center.dy));
      await tester.pump();
      await drag.moveTo(Offset(rect.center.dx, rect.center.dy));

      // Hold still well past the auto-hide delay.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(controlBarOpacity(tester), 1);

      await drag.up();
      await tester.pumpAndSettle();
    });
  });

  group('seek handle does not jump', () {
    setUp(() => fake = _FakeVideoPlayerPlatform());

    /// Reads the seek bar's current value in seconds.
    double sliderValue(WidgetTester tester) =>
        tester.widget<Slider>(find.byKey(const ValueKey('seek-bar'))).value;

    testWidgets('the handle holds its spot while the seek is still in flight', (WidgetTester tester) async {
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();

      final Rect rect = tester.getRect(find.byKey(const ValueKey('seek-bar')));
      final TestGesture drag =
          await tester.startGesture(Offset(rect.left + 26, rect.center.dy));
      await tester.pump();
      await drag.moveTo(Offset(rect.center.dx, rect.center.dy));
      await tester.pump();

      final double dragged = sliderValue(tester);
      expect(dragged, greaterThan(30));

      // Hold the seek open, then release. This is the regression: the handle
      // used to fall back to the old position for a frame before jumping.
      fake.seekGate = Completer<void>();
      await drag.up();
      await tester.pump();
      expect(sliderValue(tester), closeTo(dragged, 1));

      await tester.pump(const Duration(milliseconds: 200));
      expect(sliderValue(tester), closeTo(dragged, 1));

      fake.seekGate!.complete();
      await tester.pumpAndSettle();
      expect(sliderValue(tester), closeTo(dragged, 1));
    });

    testWidgets('a stale position poll cannot drag the handle backwards', (WidgetTester tester) async {
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();

      final Rect rect = tester.getRect(find.byKey(const ValueKey('seek-bar')));
      final TestGesture drag =
          await tester.startGesture(Offset(rect.left + 26, rect.center.dy));
      await tester.pump();
      await drag.moveTo(Offset(rect.center.dx, rect.center.dy));
      await tester.pump();
      final double dragged = sliderValue(tester);

      // Every poll from here reports the pre-seek position.
      fake.reportStalePosition = true;
      await drag.up();
      await tester.pump();

      // Stale polls land throughout the settle window and are all ignored.
      for (int i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(sliderValue(tester), closeTo(dragged, 1));
      }

      // In reality the stale polls have drained by now; once they report the
      // real position the handle hands control back without moving.
      fake.reportStalePosition = false;
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(sliderValue(tester), closeTo(dragged, 1.5));
    });

    testWidgets('the handle follows playback again once the seek settles', (WidgetTester tester) async {
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();

      final Rect rect = tester.getRect(find.byKey(const ValueKey('seek-bar')));
      final TestGesture drag =
          await tester.startGesture(Offset(rect.left + 26, rect.center.dy));
      await tester.pump();
      await drag.moveTo(Offset(rect.center.dx, rect.center.dy));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();

      // Held target released: the widget is back on live playback.
      await tester.pump(const Duration(milliseconds: 600));
      expect(sliderValue(tester),
          closeTo(fake.seekedTo.inMilliseconds / 1000, 1.5));
    });
  });

  group('fails to load', () {
    setUp(() => fake = _FakeVideoPlayerPlatform(failOnCreate: true));

    testWidgets('Retry rebuilds the controller and plays once it succeeds', (WidgetTester tester) async {
      await pumpApp(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not load the video'), findsOneWidget);

      // Simulate pasting a fresh jwt, then tapping Retry.
      fake.recover();
      fake.calls.clear();
      await tester.tap(find.byKey(const ValueKey('retry-button')));
      await tester.pump();

      expect(fake.calls, contains('create'));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      fake.completeInitialization();
      await tester.pumpAndSettle();

      expect(find.byType(VideoPlayer), findsOneWidget);
      expect(find.textContaining('Could not load the video'), findsNothing);
    });

    testWidgets('shows the error message, with no spinner and no play button', (WidgetTester tester) async {
      await pumpApp(tester);
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not load the video'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(VideoPlayer), findsNothing);
      // A play button would do nothing here, so it must not appear.
      expect(find.byKey(const ValueKey('play-pause-button')), findsNothing);
      // But there must be a way to retry.
      expect(find.byKey(const ValueKey('retry-button')), findsOneWidget);
    });
  });

  testWidgets('the app bar always shows the app name', (WidgetTester tester) async {
    fake = _FakeVideoPlayerPlatform();
    await pumpApp(tester);

    expect(find.widgetWithText(AppBar, 'TUMLive Player'), findsOneWidget);
  });
}
