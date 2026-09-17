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
import 'package:shared_preferences/shared_preferences.dart';
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
  Future<void> setMixWithOthers(bool mixWithOthers) async {
    calls.add('mixWithOthers:$mixWithOthers');
  }

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
  Future<void> pumpApp(
    WidgetTester tester, {
    bool isFullscreen = false,
    List<Widget> extraControls = const <Widget>[],
    VoidCallback? onToggleFullscreen,
    String? overlayVideoUrl,
    double gestureInsetBottom = 0,
  }) async {
    VideoPlayerPlatform.instance = fake;
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        // LecturePlayer is only the picture now: no Scaffold, no AppBar, so it
        // can sit in a 16:9 slot with a lecture list underneath. Material
        // widgets inside it still need a Material ancestor, which PlayerPage
        // provides in the real app.
        // MediaQuery goes *under* MaterialApp: the app builds its own from the
        // test view, so overriding above it would just be replaced.
        home: Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              systemGestureInsets: EdgeInsets.only(bottom: gestureInsetBottom),
            ),
            child: Scaffold(
              body: LecturePlayer(
                videoUrl: 'https://example.invalid/playlist.m3u8',
                overlayVideoUrl: overlayVideoUrl,
                title: 'TUMLive Player',
                isFullscreen: isFullscreen,
                extraControls: extraControls,
                onToggleFullscreen: onToggleFullscreen,
              ),
            ),
          ),
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

      expect(find.text('00:00/03:05'), findsOneWidget);
    });

    testWidgets('durations past an hour render as h:mm:ss', (WidgetTester tester) async {
      fake = _FakeVideoPlayerPlatform(
        duration: const Duration(hours: 1, minutes: 32, seconds: 7),
      );
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();

      expect(find.text('00:00/1:32:07'), findsOneWidget);
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

  group('gestures over the picture', () {
    setUp(() => fake = _FakeVideoPlayerPlatform());

    /// The picture's centre, which is clear of both control bars.
    Offset pictureCentre(WidgetTester tester) =>
        tester.getRect(find.byKey(const ValueKey('player-surface'))).center;

    testWidgets('a single tap hides the controls rather than pausing', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();
      expect(controlBarOpacity(tester), 1);

      fake.calls.clear();
      await tester.tapAt(pictureCentre(tester));

      // Inside the 250ms window the bar has not moved: a second tap could
      // still arrive, and a double tap must never make it flicker.
      await tester.pump(const Duration(milliseconds: 200));
      expect(controlBarOpacity(tester), 1);

      // Window closed, fade done.
      await tester.pump(const Duration(milliseconds: 300));
      expect(controlBarOpacity(tester), 0);
      expect(fake.calls, isNot(contains('pause')));
    });

    testWidgets('a double tap pauses without waking the controls',
        (WidgetTester tester) async {
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();
      // Let the bar put itself away first.
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(controlBarOpacity(tester), 0);

      fake.calls.clear();
      final Offset centre = pictureCentre(tester);
      await tester.tapAt(centre);
      await tester.pump(const Duration(milliseconds: 50));
      // Mid-pair: the first tap on its own has changed nothing, so there is no
      // flash of the bar to pull back.
      expect(controlBarOpacity(tester), 0);

      await tester.tapAt(centre);
      await tester.pumpAndSettle();

      expect(fake.calls, contains('pause'));
      expect(controlBarOpacity(tester), 0);
    });

    testWidgets('a double tap leaves a visible bar visible',
        (WidgetTester tester) async {
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();
      expect(controlBarOpacity(tester), 1);

      fake.calls.clear();
      final Offset centre = pictureCentre(tester);
      await tester.tapAt(centre);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(centre);
      await tester.pumpAndSettle();

      expect(fake.calls, contains('pause'));
      expect(controlBarOpacity(tester), 1);
    });

    testWidgets('a horizontal drag scrubs, then seeks on release', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();

      fake.calls.clear();
      final TestGesture drag = await tester.startGesture(pictureCentre(tester));
      // In steps, with time passing: a single teleporting move does not look
      // like a drag to the recognizer.
      for (int i = 0; i < 4; i++) {
        await drag.moveBy(const Offset(40, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }

      // Mid-drag: readout up, bar up so the handle shows the distance
      // travelled, playback held still.
      expect(find.byKey(const ValueKey('scrub-indicator')), findsOneWidget);
      expect(controlBarOpacity(tester), 1);
      expect(fake.calls, contains('pause'));
      expect(fake.calls, isNot(contains('seekTo')));

      // A slow swipe outlasts the 3s auto-hide, which must not fire while the
      // finger is still down — the handle is the whole point of the bar here.
      await tester.pump(const Duration(seconds: 4));
      expect(controlBarOpacity(tester), 1);

      await drag.up();
      await tester.pumpAndSettle();

      expect(fake.calls, contains('seekTo'));
      expect(fake.seekedTo, greaterThan(Duration.zero));
      expect(find.byKey(const ValueKey('scrub-indicator')), findsNothing);
      // Dragging right moves forward, and 160px is well short of the whole
      // 3m05s video.
      expect(fake.seekedTo, lessThan(const Duration(minutes: 3, seconds: 5)));
    });

    testWidgets('dragging left of the start clamps at zero', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();

      final TestGesture drag = await tester.startGesture(pictureCentre(tester));
      for (int i = 0; i < 6; i++) {
        await drag.moveBy(const Offset(-60, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.byKey(const ValueKey('scrub-indicator')), findsOneWidget);
      await drag.up();
      await tester.pumpAndSettle();

      expect(fake.seekedTo, Duration.zero);
    });

    testWidgets('a tap that never travels does not disturb playback', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();

      fake.calls.clear();
      // A press and release with no movement can still be handed to the drag
      // recognizer. It must not pause, seek, or show the readout.
      final TestGesture drag = await tester.startGesture(pictureCentre(tester));
      await drag.up();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(fake.calls, isNot(contains('seekTo')));
      expect(find.byKey(const ValueKey('scrub-indicator')), findsNothing);
    });
  });

  group('the bar is compact', () {
    setUp(() => fake = _FakeVideoPlayerPlatform());

    testWidgets('the bottom bar stays a thin strip', (WidgetTester tester) async {
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();

      // 54dp: a 14 gradient runway over a single 40dp row. Bilibili's bar is
      // a strip over the picture, not a toolbar under it, and on a 16:9 phone
      // slot every dp it takes is a dp of video it covers. Stacking the track
      // on its own line above the row is what this number guards against.
      expect(
        tester.getSize(find.byKey(const ValueKey('control-bar'))).height,
        lessThanOrEqualTo(58),
      );
    });

    testWidgets('the track shares the row rather than taking its own', (WidgetTester tester) async {
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();

      final Rect seek = tester.getRect(find.byKey(const ValueKey('seek-bar')));
      final Rect play = tester.getRect(
        find.byKey(const ValueKey('play-pause-button')),
      );
      // Same line as the play button, and starting to its right.
      expect(seek.center.dy, closeTo(play.center.dy, 1));
      expect(seek.left, greaterThan(play.right - 1));
    });

    testWidgets('the play button does not claim a 48dp tap target', (WidgetTester tester) async {
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();

      // This alone used to set the bar's height: IconButton takes its tap
      // target from the theme, so it ignores `constraints` and visualDensity.
      expect(
        tester.getSize(find.byKey(const ValueKey('play-pause-button'))).height,
        lessThanOrEqualTo(36),
      );
    });

    testWidgets('a fullscreen seek bar sits clear of the navigation gesture', (WidgetTester tester) async {
      // Android gesture navigation reserves 48dp at the bottom. A drag that
      // starts in there means "go home" and never reaches the Slider, so a
      // seek bar flush with the screen edge backgrounds the app instead of
      // scrubbing. immersiveSticky zeroes viewPadding while the gesture keeps
      // firing, which is why the bar has to read systemGestureInsets and a
      // SafeArea would not have caught this.
      await pumpApp(tester, isFullscreen: true, gestureInsetBottom: 48);
      fake.completeInitialization();
      await tester.pumpAndSettle();

      final Rect seek = tester.getRect(find.byKey(const ValueKey('seek-bar')));
      final Rect bar = tester.getRect(find.byKey(const ValueKey('control-bar')));
      expect(seek.bottom, lessThanOrEqualTo(bar.bottom - 48));
    });

    testWidgets('a windowed seek bar is not pushed up by the gesture strip', (WidgetTester tester) async {
      // Windowed, the picture is a 16:9 slot with the lecture list under it, so
      // the bar is nowhere near the screen edge and owes the gesture nothing.
      await pumpApp(tester, gestureInsetBottom: 48);
      fake.completeInitialization();
      await tester.pumpAndSettle();

      final Rect seek = tester.getRect(find.byKey(const ValueKey('seek-bar')));
      final Rect bar = tester.getRect(find.byKey(const ValueKey('control-bar')));
      expect(seek.bottom, greaterThan(bar.bottom - 48));
    });
  });

  group('what the bar carries', () {
    setUp(() => fake = _FakeVideoPlayerPlatform());

    const Widget angle = Icon(
      Icons.switch_video_outlined,
      key: ValueKey<String>('angle-switcher'),
    );

    testWidgets('the 16:9 bar carries nothing but the way into fullscreen', (
      WidgetTester tester,
    ) async {
      await pumpApp(
        tester,
        extraControls: <Widget>[angle],
        onToggleFullscreen: () {},
      );
      fake.completeInitialization();
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('fullscreen-button')), findsOneWidget);
      // Settings, not controls: they would crowd a 560dp-wide bar sitting on
      // top of the video.
      expect(find.byKey(const ValueKey('speed-menu')), findsNothing);
      expect(find.byKey(const ValueKey('angle-switcher')), findsNothing);
    });

    testWidgets('fullscreen is where speed and camera angle live', (
      WidgetTester tester,
    ) async {
      await pumpApp(
        tester,
        isFullscreen: true,
        extraControls: <Widget>[angle],
        onToggleFullscreen: () {},
      );
      fake.completeInitialization();
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('speed-menu')), findsOneWidget);
      expect(find.byKey(const ValueKey('angle-switcher')), findsOneWidget);
      expect(find.byKey(const ValueKey('fullscreen-button')), findsOneWidget);
    });

    testWidgets('the 16:9 slot has no fill-screen control', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, onToggleFullscreen: () {});
      fake.completeInitialization();
      await tester.pumpAndSettle();

      // Nothing to reclaim in a 16:9 box, and the bar has no room for it.
      expect(find.byKey(const ValueKey('fill-screen-button')), findsNothing);
    });

    testWidgets('fullscreen offers fill-screen', (WidgetTester tester) async {
      await pumpApp(tester, isFullscreen: true, onToggleFullscreen: () {});
      fake.completeInitialization();
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('fill-screen-button')), findsOneWidget);
    });

    testWidgets('filling crops from the bottom, not the middle', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, isFullscreen: true, onToggleFullscreen: () {});
      fake.completeInitialization();
      await tester.pumpAndSettle();

      // Letterboxed to begin with: the whole frame, nothing cropped.
      expect(find.byType(FittedBox), findsNothing);

      await tester.tap(find.byKey(const ValueKey('fill-screen-button')));
      await tester.pumpAndSettle();

      final FittedBox fitted = tester.widget<FittedBox>(
        find
            .ancestor(
              of: find.byType(VideoPlayer),
              matching: find.byType(FittedBox),
            )
            .first,
      );
      expect(fitted.fit, BoxFit.cover);
      // Top-anchored on purpose: TUM's combined stream keeps its slides and
      // camera in the top of the frame and pads the bottom with black, so a
      // centred crop would cut the content and leave the padding.
      expect(fitted.alignment, Alignment.topCenter);
    });

    testWidgets('the fullscreen button reports the tap', (
      WidgetTester tester,
    ) async {
      int taps = 0;
      await pumpApp(tester, onToggleFullscreen: () => taps++);
      fake.completeInitialization();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('fullscreen-button')));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });

    testWidgets('no callback, no button', (WidgetTester tester) async {
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('fullscreen-button')), findsNothing);
    });
  });

  group('fused source', () {
    setUp(() {
      fake = _FakeVideoPlayerPlatform();
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    testWidgets('no overlay url, no second picture', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester);
      fake.completeInitialization();
      await tester.pumpAndSettle();

      expect(find.byType(VideoPlayer), findsOneWidget);
    });

    testWidgets('the camera is inset over the bottom-right of the slides', (
      WidgetTester tester,
    ) async {
      await pumpApp(
        tester,
        overlayVideoUrl: 'https://example.invalid/cam.m3u8',
      );
      fake.completeInitialization();
      await tester.pumpAndSettle();

      // Both streams on screen: slides underneath, camera over them.
      expect(find.byType(VideoPlayer), findsNWidgets(2));

      final Rect player = tester.getRect(
        find.byKey(const ValueKey('player-surface')),
      );
      // The slides picture, which on this 800x600 surface is a 16:9 band with
      // letterboxing above and below.
      final Rect slides = tester.getRect(find.byType(VideoPlayer).first);
      final Rect inset = tester.getRect(find.byType(VideoPlayer).last);

      expect(inset.left, greaterThan(player.center.dx));
      expect(inset.top, greaterThan(player.center.dy));
      // Tucked into the slides' own corner, not the player's — the player's
      // right edge is letterbox black on a wide screen.
      expect(inset.right, lessThanOrEqualTo(slides.right));
      expect(inset.right, greaterThan(slides.right - 24));
      expect(inset.bottom, lessThanOrEqualTo(slides.bottom));
      // And small: a glance at the lecturer, not a second thing to watch.
      expect(inset.width, lessThan(slides.width / 4));
    });

    testWidgets('pausing the slides pauses the camera with them', (
      WidgetTester tester,
    ) async {
      await pumpApp(
        tester,
        overlayVideoUrl: 'https://example.invalid/cam.m3u8',
      );
      fake.completeInitialization();
      await tester.pumpAndSettle();

      fake.calls.clear();
      await tester.tap(find.byKey(const ValueKey('play-pause-button')));
      await tester.pumpAndSettle();

      // Both decoders, not just the one the button owns — two streams that
      // disagree about whether they are running is the whole risk here.
      expect(fake.calls.where((String c) => c == 'pause').length, 2);
    });

    testWidgets('the inset is smaller in a 16:9 slot than in fullscreen', (
      WidgetTester tester,
    ) async {
      await pumpApp(
        tester,
        overlayVideoUrl: 'https://example.invalid/cam.m3u8',
      );
      fake.completeInitialization();
      await tester.pumpAndSettle();
      final double windowed = tester
          .getRect(find.byType(VideoPlayer).last)
          .width;

      await pumpApp(
        tester,
        isFullscreen: true,
        overlayVideoUrl: 'https://example.invalid/cam.m3u8',
      );
      await tester.pumpAndSettle();
      final double full = tester.getRect(find.byType(VideoPlayer).last).width;

      // A 16:9 box on a phone has far less room to give away than a whole
      // screen does.
      expect(windowed, lessThan(full));
    });

    testWidgets('the inset can be dragged around the slides', (
      WidgetTester tester,
    ) async {
      await pumpApp(
        tester,
        overlayVideoUrl: 'https://example.invalid/cam.m3u8',
      );
      fake.completeInitialization();
      await tester.pumpAndSettle();

      final Rect before = tester.getRect(find.byType(VideoPlayer).last);
      // From the middle of the inset: the corners resize, the middle moves.
      await tester.dragFrom(before.center, const Offset(-120, -60));
      await tester.pumpAndSettle();

      final Rect after = tester.getRect(find.byType(VideoPlayer).last);
      expect(after.left, closeTo(before.left - 120, 1));
      expect(after.top, closeTo(before.top - 60, 1));
      expect(after.size, before.size);
    });

    testWidgets('a drag cannot push the inset off the slides', (
      WidgetTester tester,
    ) async {
      await pumpApp(
        tester,
        overlayVideoUrl: 'https://example.invalid/cam.m3u8',
      );
      fake.completeInitialization();
      await tester.pumpAndSettle();

      final Rect slides = tester.getRect(find.byType(VideoPlayer).first);
      await tester.dragFrom(
        tester.getRect(find.byType(VideoPlayer).last).center,
        const Offset(4000, 4000),
      );
      await tester.pumpAndSettle();

      final Rect after = tester.getRect(find.byType(VideoPlayer).last);
      expect(after.right, lessThanOrEqualTo(slides.right + 1));
      expect(after.bottom, lessThanOrEqualTo(slides.bottom + 1));
    });

    testWidgets('any corner resizes, pinning the one opposite', (
      WidgetTester tester,
    ) async {
      // A small inset parked away from the edges, so a resize in any direction
      // has room to actually happen.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'tumlive.inset_right': 0.35,
        'tumlive.inset_bottom': 0.35,
        'tumlive.inset_width': 0.15,
      });
      await pumpApp(
        tester,
        overlayVideoUrl: 'https://example.invalid/cam.m3u8',
      );
      fake.completeInitialization();
      await tester.pumpAndSettle();

      Rect inset() => tester.getRect(find.byType(VideoPlayer).last);

      // Each corner, dragged diagonally outwards.
      for (final (String name, bool left, bool top) in <(String, bool, bool)>[
        ('topLeft', true, true),
        ('topRight', false, true),
        ('bottomLeft', true, false),
        ('bottomRight', false, false),
      ]) {
        final Rect before = inset();
        // Six pixels inside the corner, which is within the grab zone.
        final Offset grab = Offset(
          left ? before.left + 6 : before.right - 6,
          top ? before.top + 6 : before.bottom - 6,
        );
        final Offset outwards = Offset(left ? -40 : 40, top ? -20 : 20);

        await tester.dragFrom(grab, outwards);
        await tester.pumpAndSettle();
        final Rect after = inset();

        expect(after.width, greaterThan(before.width), reason: '$name grows');
        // The pinned corner is the one diagonally opposite.
        expect(
          left ? after.right : after.left,
          closeTo(left ? before.right : before.left, 1),
          reason: '$name pins the far side',
        );
        expect(
          top ? after.bottom : after.top,
          closeTo(top ? before.bottom : before.top, 1),
          reason: '$name pins the far edge',
        );

        // Shrink it back so every corner starts from the same size.
        await tester.dragFrom(
          Offset(
            left ? after.left + 6 : after.right - 6,
            top ? after.top + 6 : after.bottom - 6,
          ),
          -outwards,
        );
        await tester.pumpAndSettle();
      }
    });

    testWidgets('a corner can be grabbed from just outside the picture', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'tumlive.inset_right': 0.35,
        'tumlive.inset_bottom': 0.35,
        'tumlive.inset_width': 0.15,
      });
      await pumpApp(
        tester,
        overlayVideoUrl: 'https://example.invalid/cam.m3u8',
      );
      fake.completeInitialization();
      await tester.pumpAndSettle();

      final Rect before = tester.getRect(find.byType(VideoPlayer).last);
      // Outside the video the user can see, inside the region they can grab.
      // A thumb aiming at a 120x68 window's corner does not land on the pixel.
      await tester.dragFrom(
        before.topLeft - const Offset(6, 6),
        const Offset(-40, -20),
      );
      await tester.pumpAndSettle();

      final Rect after = tester.getRect(find.byType(VideoPlayer).last);
      expect(after.width, greaterThan(before.width));
      expect(after.right, closeTo(before.right, 1));
    });

    testWidgets('nothing is drawn on the inset to advertise resizing', (
      WidgetTester tester,
    ) async {
      await pumpApp(
        tester,
        overlayVideoUrl: 'https://example.invalid/cam.m3u8',
      );
      fake.completeInitialization();
      await tester.pumpAndSettle();

      // The grab zones are real but invisible: a badge on the lecturer's face
      // for the whole lecture is a poor way to say "this corner is draggable".
      // The grab zones are real but invisible: a badge on the lecturer's face
      // for the whole lecture is a poor way to say "this corner is draggable".
      expect(find.byIcon(Icons.open_in_full_rounded), findsNothing);
      expect(find.byKey(const ValueKey<String>('camera-inset')), findsOneWidget);
    });

    testWidgets('a moved inset comes back where it was left', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'tumlive.inset_right': 0.5,
        'tumlive.inset_bottom': 0.4,
        'tumlive.inset_width': 0.3,
      });
      await pumpApp(
        tester,
        overlayVideoUrl: 'https://example.invalid/cam.m3u8',
      );
      fake.completeInitialization();
      await tester.pumpAndSettle();

      final Rect slides = tester.getRect(find.byType(VideoPlayer).first);
      final Rect inset = tester.getRect(find.byType(VideoPlayer).last);
      expect(inset.width, closeTo(slides.width * 0.3, 1));
      expect(slides.right - inset.right, closeTo(slides.width * 0.5, 1));
      expect(slides.bottom - inset.bottom, closeTo(slides.height * 0.4, 1));
    });

    testWidgets('a stored position too big for this screen is pulled back in', (
      WidgetTester tester,
    ) async {
      // Dragged to a corner of some larger screen, then opened on a smaller
      // one. An inset parked outside the picture could never be dragged back.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'tumlive.inset_right': 0.95,
        'tumlive.inset_bottom': 0.95,
        'tumlive.inset_width': 0.9,
      });
      await pumpApp(
        tester,
        overlayVideoUrl: 'https://example.invalid/cam.m3u8',
      );
      fake.completeInitialization();
      await tester.pumpAndSettle();

      final Rect slides = tester.getRect(find.byType(VideoPlayer).first);
      final Rect inset = tester.getRect(find.byType(VideoPlayer).last);
      expect(inset.left, greaterThanOrEqualTo(slides.left - 1));
      expect(inset.top, greaterThanOrEqualTo(slides.top - 1));
      expect(inset.width, lessThanOrEqualTo(slides.width / 2 + 1));
    });

    testWidgets('the camera declines audio focus, the slides keep it', (
      WidgetTester tester,
    ) async {
      await pumpApp(
        tester,
        overlayVideoUrl: 'https://example.invalid/cam.m3u8',
      );
      fake.completeInitialization();
      await tester.pumpAndSettle();

      // Order matters: the platform reads this as one global flag when a
      // player is created. The slides are created first and take focus; the
      // camera is created second and declines it. Both asking for exclusive
      // focus is what made the two streams pause each other dead on a device.
      final List<String> focus = fake.calls
          .where((String c) => c.startsWith('mixWithOthers:'))
          .toList();
      expect(focus, <String>['mixWithOthers:false', 'mixWithOthers:true']);
    });

    testWidgets('the inset clears the control bar and never moves', (
      WidgetTester tester,
    ) async {
      await pumpApp(
        tester,
        overlayVideoUrl: 'https://example.invalid/cam.m3u8',
      );
      fake.completeInitialization();
      await tester.pumpAndSettle();

      // Clear of the bar while the bar is up...
      expect(controlBarOpacity(tester), 1);
      final Rect bar = tester.getRect(find.byKey(const ValueKey('control-bar')));
      final Rect raised = tester.getRect(find.byType(VideoPlayer).last);
      expect(raised.bottom, lessThanOrEqualTo(bar.top + 1));

      // ...and in exactly the same place once it goes away. The inset is meant
      // to sit in the background; shifting it whenever the bar is summoned
      // pulled the eye straight to it.
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(controlBarOpacity(tester), 0);
      expect(tester.getRect(find.byType(VideoPlayer).last), raised);
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
      expect(find.text('00:00/03:05'), findsOneWidget);

      final Rect rect = tester.getRect(find.byKey(const ValueKey('seek-bar')));
      final TestGesture drag =
          await tester.startGesture(Offset(rect.left + 26, rect.center.dy));
      await tester.pump();
      await drag.moveTo(Offset(rect.center.dx, rect.center.dy));
      await tester.pumpAndSettle();

      // Still 03:05 total, but the left half now shows the drag target.
      expect(find.text('00:00/03:05'), findsNothing);
      expect(find.textContaining('/03:05'), findsOneWidget);

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

  testWidgets('the title is shown over the picture, not in an app bar',
      (WidgetTester tester) async {
    fake = _FakeVideoPlayerPlatform();
    await pumpApp(tester);
    fake.completeInitialization();
    await tester.pumpAndSettle();

    // An app bar would cost ~56dp of height permanently on a phone. The title
    // rides in the overlay that fades with the rest of the controls instead.
    expect(find.byType(AppBar), findsNothing);
    expect(find.text('TUMLive Player'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('top-bar')), findsOneWidget);
  });
}
