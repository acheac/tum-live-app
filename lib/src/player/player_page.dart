/// Turns `(courseSlug, lectureId)` into a playing video, with the rest of the
/// course listed underneath.
///
/// This is the layer that exists because **playlist URLs expire**. gocast signs
/// them with a JWT that lives about seven hours, so the app stores lecture ids
/// and resolves a fresh URL immediately before playback. Never the other way
/// round — that is what made an early hardcoded link rot every day.
///
/// Layout follows the phone video-app convention: the picture sits in a 16:9
/// slot at the top with its controls overlaid, and everything else scrolls
/// below it. Fullscreen gives the picture the whole screen and turns the phone
/// with it — but only when the button is pressed. The page pins the
/// orientation while it is open, so the accelerometer never decides this:
/// lying down with the phone should not throw a lecture into fullscreen.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api_exception.dart';
import '../api/models.dart';
import '../api/tum_live_api.dart';
import '../app_scope.dart';
import '../auth/auth_controller.dart';
import '../common/async_builder.dart';
import '../common/formatting.dart';
import '../common/orientation.dart';
import '../common/pin_button.dart';
import 'lecture_player.dart';
import 'player_controls.dart';
import 'player_preferences.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.courseSlug,
    required this.lectureId,
    this.courseName,
  });

  final String courseSlug;
  final int lectureId;

  /// Shown while the lecture itself is still loading.
  final String? courseName;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

/// Everything the page needs, fetched together.
class _Playback {
  const _Playback({
    required this.lecture,
    required this.course,
    required this.siblings,
    this.resumeAt,
  });

  final Lecture lecture;
  final Course course;

  /// The other lectures in this course, for the list below the player.
  final List<PlaylistEntry> siblings;
  final Duration? resumeAt;
}

class _PlayerPageState extends State<PlayerPage> {
  Future<_Playback>? _future;

  /// The angle to play. Seeded from [SourcePreference] on the first load, so
  /// the choice carries across lectures and across launches.
  LectureSource _source = LectureSource.combined;
  final SourcePreference _sourcePreference = const SourcePreference();
  bool _sourceRestored = false;

  /// The lecture on screen, which is not always the one the route was opened
  /// with: tapping a sibling swaps it in place. See [_openSibling].
  late int _lectureId = widget.lectureId;
  late String _courseSlug = widget.courseSlug;

  /// The last playback that finished loading.
  ///
  /// Kept so a lecture switch can leave the page standing — heading, list and
  /// the video still playing — while the next lecture resolves. Replacing
  /// [_future] on its own drops the whole screen to a spinner, which is what
  /// made switching feel like opening a new page.
  _Playback? _loaded;

  /// Which lecture a tap is waiting on, so its row can say so.
  int? _switchingTo;

  /// Whether the video is running, for the animated marker in the list.
  bool _isPlaying = false;

  /// Where to start playback. Seeded from the server's stored progress, then
  /// updated locally so switching camera angles does not lose your place.
  Duration? _resumeTarget;

  DateTime _lastReport = DateTime.fromMillisecondsSinceEpoch(0);
  Duration _lastPosition = Duration.zero;

  /// The last duration playback reported.
  ///
  /// Needed because a final report — on leaving the page, or on switching
  /// lecture — has no duration to hand. Without it those reports computed a
  /// fraction against zero and bailed out, so the position was quietly never
  /// saved on the way out.
  Duration _lastDuration = Duration.zero;

  /// Reporting on every frame would be thousands of requests per lecture.
  static const Duration _reportInterval = Duration(seconds: 5);

  /// Past this fraction we call the lecture watched.
  static const double _watchedThreshold = 0.9;

  /// The single source of truth for fullscreen.
  ///
  /// Deliberately not derived from [MediaQuery.orientationOf]: the page pins
  /// the phone to portrait while it is open, so the accelerometer never gets a
  /// say. Rotating a phone that is lying on a desk, or turning over in bed,
  /// used to throw the video into fullscreen unasked. Now the button is the
  /// only way in or out, which also means the layout can never disagree with
  /// the orientation we asked the platform for.
  bool _forcedFullscreen = false;

  /// Cached so [dispose] can still report a final position after the element
  /// is unmounted, when `context` is no longer safe to read.
  TumLiveApi? _api;
  AuthController? _auth;

  /// The orientations this screen size allows, cached for the same reason.
  List<DeviceOrientation>? _allowed;

  @override
  void initState() {
    super.initState();
  }

  // The first load happens here, not in initState: reading an InheritedWidget
  // registers a dependency, and initState is too early for that.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _api = AppScope.apiOf(context);
    _auth = AppScope.authOf(context);
    _allowed = allowedOrientations(MediaQuery.of(context));
    // Rotation is the screen's decision, not this page's — on a phone that is
    // portrait, which is what the fullscreen button exists to replace. Skipped
    // while fullscreen: that state pins landscape on purpose, and the window
    // resizing as the system bars hide would otherwise stand the video back up
    // mid-lecture.
    if (!_forcedFullscreen) unawaited(_applyPolicy());
    _future ??= _load();
  }

  @override
  void dispose() {
    // One last report so closing the page mid-lecture still records where you
    // got to. Fire-and-forget: the page is going away either way.
    unawaited(_reportProgress(lectureId: _lectureId, force: true));
    // Never leave the rest of the app locked sideways, whatever state the
    // player was in when it was closed. Back to what the screen allows rather
    // than to every orientation: on a phone the answer is portrait, and
    // handing back DeviceOrientation.values here would switch rotation on for
    // the course list the user is returning to.
    unawaited(
      SystemChrome.setPreferredOrientations(
        _allowed ?? DeviceOrientation.values,
      ),
    );
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  /// Hands orientation back to [allowedOrientations] for this screen.
  Future<void> _applyPolicy() => SystemChrome.setPreferredOrientations(
    _allowed ?? const <DeviceOrientation>[DeviceOrientation.portraitUp],
  );

  /// Enters or leaves fullscreen by turning the phone.
  ///
  /// On a phone the orientation is pinned both ways — portrait outside
  /// fullscreen, landscape inside — so there is no race on the way out: the
  /// platform cannot put us back into landscape behind our back.
  ///
  /// On a tablet the outside state allows every orientation, so the screen can
  /// be landscape with [_forcedFullscreen] false. Nothing reads orientation to
  /// decide fullscreen, only this flag, so the two are allowed to disagree —
  /// which is the same thing that lets a landscape window keep showing the
  /// lecture list.
  Future<void> _toggleFullscreen(bool isFullscreen) async {
    setState(() => _forcedFullscreen = !isFullscreen);
    if (isFullscreen) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await _applyPolicy();
      return;
    }
    // Both landscapes: which way the phone is held is still the user's call.
    await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  Future<_Playback> _load() async {
    final TumLiveApi api = _api!;
    final AuthController auth = _auth!;

    final CourseLecture result = await api.getLecture(_courseSlug, _lectureId);

    // The sibling list and the stored progress are both optional garnish, so
    // they run together and neither can block playback.
    // Before the first lecture resolves, so the player is built with the angle
    // the user actually wants rather than switching to it a frame later — that
    // would throw away a controller that had only just started loading.
    if (!_sourceRestored) {
      _sourceRestored = true;
      _source = await _sourcePreference.read() ?? _source;
    }

    final List<PlaylistEntry> siblings = await api
        .getLecturePlaylist(_courseSlug, _lectureId)
        .catchError((Object _) => const <PlaylistEntry>[]);

    Duration? resumeAt;
    if (auth.isSignedIn) {
      try {
        final Map<int, LectureProgress> progress = await api.getProgress(<int>[
          _lectureId,
        ]);
        final LectureProgress? stored = progress[_lectureId];
        final Duration total = result.lecture.duration;
        if (stored != null && stored.isStarted && total > Duration.zero) {
          resumeAt = total * stored.progress;
        }
      } on Object {
        // Progress is a nicety. Never let it stop playback.
      }
    }

    _resumeTarget ??= resumeAt;
    final _Playback playback = _Playback(
      lecture: result.lecture,
      course: result.course,
      siblings: siblings,
      resumeAt: _resumeTarget,
    );
    // Held for the next switch to render against. The rebuild that follows the
    // future completing is what puts it on screen.
    _loaded = playback;
    _switchingTo = null;
    return playback;
  }

  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  /// Switches to another lecture in place.
  ///
  /// This used to `pushReplacement` a whole new [PlayerPage], which threw away
  /// the page and rebuilt it: full-screen spinner, list gone, everything
  /// re-fetched. Nothing about it needed a new route — only the lecture id
  /// changes, so the id is state and the page reloads just the part that moved.
  void _openSibling(PlaylistEntry entry) {
    if (entry.lectureId == _lectureId) return;
    // Save where we got to in the lecture being left, before the id moves on.
    unawaited(_reportProgress(lectureId: _lectureId, force: true));
    setState(() {
      _switchingTo = entry.lectureId;
      if (entry.courseSlug.isNotEmpty) _courseSlug = entry.courseSlug;
      _lectureId = entry.lectureId;
      // A different lecture resumes where the server says it should, not where
      // the last one happened to be. _load() does `??=`, so without clearing
      // this the new lecture would open at the old one's position.
      _resumeTarget = null;
      _lastPosition = Duration.zero;
      _lastDuration = Duration.zero;
      _lastReport = DateTime.fromMillisecondsSinceEpoch(0);
      _future = _load();
    });
  }

  /// Remembers the position and, at most every [_reportInterval], tells the
  /// server about it.
  void _handlePosition(Duration position, Duration duration) {
    _lastPosition = position;
    _lastDuration = duration;
    if (duration <= Duration.zero) return;
    if (DateTime.now().difference(_lastReport) < _reportInterval) return;
    unawaited(_reportProgress(lectureId: _lectureId, total: duration));
  }

  /// [lectureId] is passed in rather than read from the field: a switch reports
  /// the lecture being *left*, and by the time this runs the field has moved on.
  Future<void> _reportProgress({
    required int lectureId,
    Duration? total,
    bool force = false,
  }) async {
    if (!mounted && !force) return;
    final AuthController? auth = _auth;
    if (auth == null || !auth.isSignedIn) return;
    final Duration duration = total ?? _lastDuration;
    if (duration <= Duration.zero || _lastPosition <= Duration.zero) return;

    _lastReport = DateTime.now();
    final double fraction =
        (_lastPosition.inMilliseconds / duration.inMilliseconds).clamp(
          0.0,
          1.0,
        );
    try {
      await _api?.updateProgress(
        lectureId: lectureId,
        progress: fraction,
        watched: fraction >= _watchedThreshold,
      );
    } on ApiException {
      // A failed progress write is not worth interrupting playback for.
    } on NetworkException {
      // Same.
    }
  }

  @override
  Widget build(BuildContext context) {
    final _Playback? previous = _loaded;
    return AsyncBuilder<_Playback>(
      future: _future,
      onRetry: _reload,
      // A lecture switch keeps the page it already has, so only the very first
      // load — when there is nothing on screen to keep — gets the full-screen
      // spinner. The row being waited on says so itself.
      loadingBuilder: previous == null ? null : () => _buildLoaded(previous),
      loading: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const CircularProgressIndicator(color: Colors.white),
              if (widget.courseName != null) ...<Widget>[
                const SizedBox(height: 16),
                Text(
                  widget.courseName!,
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ],
          ),
        ),
      ),
      builder: (BuildContext context, _Playback data) => _buildLoaded(data),
    );
  }

  Widget _buildLoaded(_Playback data) {
    final Map<LectureSource, String> sources = data.lecture.availableSources;
    if (sources.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text(data.lecture.displayName)),
        body: const EmptyView(
          icon: Icons.videocam_off_outlined,
          message: 'This lecture has no recording yet.',
        ),
      );
    }

    // Fall back to whatever source exists if the chosen one is missing.
    final LectureSource source = sources.containsKey(_source)
        ? _source
        : sources.keys.first;

    final bool fullscreen = _forcedFullscreen;

    final Widget player = LecturePlayer(
      // Rebuilding with a new URL is how a source switch reaches the player;
      // the key keeps state per source rather than per page.
      key: ValueKey<String>('${data.lecture.id}-${source.name}'),
      videoUrl: sources[source]!,
      // Fused plays the slides and lays the camera over them, which is two
      // decodes at once; every other source leaves this null.
      overlayVideoUrl: source == LectureSource.fused
          ? data.lecture.fusedOverlayUrl
          : null,
      title: data.lecture.displayName,
      subtitle: data.course.name,
      startAt: data.resumeAt,
      onPositionChanged: _handlePosition,
      onPlayingChanged: (bool playing) {
        if (mounted && playing != _isPlaying) {
          setState(() => _isPlaying = playing);
        }
      },
      onRetry: _reload,
      // In fullscreen, back means "give me the page back" — leaving the lecture
      // outright from there is a bigger jump than the gesture suggests, and
      // there is no other way out of fullscreen from the top bar. A second
      // press, now in the 16:9 layout, leaves as it always did.
      onBack: fullscreen
          ? () => unawaited(_toggleFullscreen(true))
          : () => Navigator.of(context).maybePop(),
      isFullscreen: fullscreen,
      onToggleFullscreen: () => unawaited(_toggleFullscreen(fullscreen)),
      // Only reachable in fullscreen — see PlayerChrome.isFullscreen. In the
      // 16:9 slot the bar keeps just play, the track, the clock and the way
      // into fullscreen.
      extraControls: <Widget>[
        if (sources.length > 1) _buildSourceSwitcher(sources, source),
      ],
    );

    // One layout for both modes, on purpose. Two separate widget trees — a
    // bare `SafeArea(child: player)` for fullscreen and a `Column` for the
    // 16:9 slot — put the player at a different place in the element tree, so
    // switching unmounted it and built a brand new VideoPlayerController: the
    // video restarted from scratch every time. Keeping the chain identical
    // (SafeArea > LayoutBuilder > Column > SizedBox > player) means only the
    // slot's height changes and playback carries straight on.
    return PopScope(
      // The system back gesture means the same as the arrow in the top bar:
      // leave fullscreen if we are in it, leave the lecture if we are not.
      // Letting the two disagree is worse than either behaviour on its own.
      canPop: !fullscreen,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop || !fullscreen) return;
        unawaited(_toggleFullscreen(true));
      },
      child: Scaffold(
        backgroundColor: fullscreen
            ? Colors.black
            : Theme.of(context).colorScheme.surface,
        body: SafeArea(
          bottom: fullscreen,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) =>
                Column(
                  children: <Widget>[
                    SizedBox(
                      height: fullscreen
                          ? constraints.maxHeight
                          : constraints.maxWidth * 9 / 16,
                      child: player,
                    ),
                    if (!fullscreen) Expanded(child: _buildDetails(data)),
                  ],
                ),
          ),
        ),
      ),
    );
  }

  Widget _buildDetails(_Playback data) {
    final ThemeData theme = Theme.of(context);
    // The lecture being watched stays in the list, marked as playing. Dropping
    // it made the list jump by one row on every switch and gave no sense of
    // where in the course you were.
    final List<PlaylistEntry> siblings = data.siblings;

    // A Column with the list in an Expanded, not one long ListView. Which
    // lecture is playing, and the pin for its course, are what the page is
    // about — scrolling the siblings should not carry them off the top. Only
    // the list below "More in this course" moves.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 4, 8),
          // The pin sits at the right end of this row, which puts it directly
          // under the fullscreen button at the picture's bottom-right corner.
          // Only reachable here, never in fullscreen: _buildDetails is not in
          // the tree at all once the video fills the screen, and a pin is not
          // something to reach for mid-lecture.
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      data.lecture.displayName,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      <String>[
                        data.course.name,
                        if (data.lecture.start != null)
                          formatLectureDate(data.lecture.start),
                        if (data.lecture.duration > Duration.zero)
                          formatDuration(data.lecture.duration),
                      ].join(' · '),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              PinButton(course: data.course),
            ],
          ),
        ),
        const Divider(height: 24),
        // One entry means the only lecture is the one playing, so there is
        // nothing to list.
        if (siblings.length <= 1)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('No other lectures in this course.'),
          )
        else ...<Widget>[
          // The heading stays with the header, above the scroll: a list of
          // thirteen lectures whose title has scrolled away is just a list.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.playlist_play,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text('More in this course', style: theme.textTheme.titleSmall),
                const Spacer(),
                Text('${siblings.length}', style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 24),
              itemCount: siblings.length,
              itemBuilder: (BuildContext context, int i) {
                final PlaylistEntry entry = siblings[i];
                return _SiblingTile(
                  entry: entry,
                  isCurrent: entry.lectureId == data.lecture.id,
                  isPlaying: _isPlaying,
                  isLoading: _switchingTo == entry.lectureId,
                  onTap: () => _openSibling(entry),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSourceSwitcher(
    Map<LectureSource, String> sources,
    LectureSource current,
  ) {
    return Builder(
      builder: (BuildContext context) => Tooltip(
        message: 'Camera angle',
        child: InkWell(
          key: const ValueKey<String>('source-switcher'),
          onTap: () async {
            // Centred above the icon — see [showBarMenu] for why the menu
            // cannot simply be offset.
            final LectureSource? next = await showBarMenu<LectureSource>(
              context: context,
              initialValue: current,
              items: <PopupMenuEntry<LectureSource>>[
                for (final LectureSource source in sources.keys)
                  PopupMenuItem<LectureSource>(
                    value: source,
                    height: popupMenuItemHeight,
                    child: Text(
                      source.label,
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ),
              ],
            );
            if (next == null || !mounted) return;
            unawaited(_sourcePreference.write(next));
            setState(() {
              // Carry the current position across the switch.
              _resumeTarget = _lastPosition;
              _source = next;
            });
          },
          child: const SizedBox(
            width: popupMenuButtonWidth,
            height: popupMenuButtonHeight,
            child: Center(
              child: Icon(
                Icons.switch_video_outlined,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One row in the "more in this course" list.
class _SiblingTile extends StatelessWidget {
  const _SiblingTile({
    required this.entry,
    required this.onTap,
    this.isCurrent = false,
    this.isPlaying = false,
    this.isLoading = false,
  });

  final PlaylistEntry entry;
  final VoidCallback onTap;

  /// The lecture currently on screen. Marked, and not tappable — there is
  /// nothing to switch to.
  final bool isCurrent;

  /// Whether the video is running. Only meaningful with [isCurrent].
  final bool isPlaying;

  /// A tap on this row is waiting on the network.
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListTile(
      dense: true,
      selected: isCurrent,
      selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.08),
      leading: _buildLeading(theme),
      title: Text(
        entry.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: isCurrent ? FontWeight.w600 : null,
          color: isCurrent ? theme.colorScheme.primary : null,
        ),
      ),
      trailing: isCurrent
          ? Text(
              'Now playing',
              key: const ValueKey<String>('now-playing'),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            )
          : null,
      subtitle: entry.isStarted
          ? Padding(
              padding: const EdgeInsets.only(top: 6),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: entry.progress,
                  minHeight: 3,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
              ),
            )
          : null,
      onTap: isCurrent ? null : onTap,
    );
  }

  Widget _buildLeading(ThemeData theme) {
    if (isLoading) {
      return const SizedBox(
        width: 32,
        height: 32,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return CircleAvatar(
      radius: 16,
      backgroundColor: entry.liveNow
          ? theme.colorScheme.error
          : isCurrent
          ? theme.colorScheme.primary
          : theme.colorScheme.primaryContainer,
      child: isCurrent && !entry.liveNow
          // Bars that move while the video does. A static equalizer glyph said
          // "this is the one" but not "and it is running" — which is the thing
          // you actually want to know at a glance after tapping around.
          ? _PlayingBars(
              key: const ValueKey<String>('playing-bars'),
              playing: isPlaying,
              color: theme.colorScheme.onPrimary,
            )
          : Icon(
              entry.liveNow
                  ? Icons.sensors
                  : entry.watched
                  ? Icons.check
                  : Icons.play_arrow,
              size: 16,
              color: entry.liveNow
                  ? theme.colorScheme.onError
                  : theme.colorScheme.onPrimaryContainer,
            ),
    );
  }
}

/// Three bars that rise and fall while [playing], and hold still when not.
///
/// Deliberately hand-painted rather than an animated GIF or a Lottie file: it
/// is three rectangles, it has to take its colour from the theme, and it must
/// stop dead when playback pauses.
class _PlayingBars extends StatefulWidget {
  const _PlayingBars({super.key, required this.playing, required this.color});

  final bool playing;
  final Color color;

  @override
  State<_PlayingBars> createState() => _PlayingBarsState();
}

class _PlayingBarsState extends State<_PlayingBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.playing) _controller.repeat();
  }

  @override
  void didUpdateWidget(_PlayingBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playing == oldWidget.playing) return;
    // Stopping rather than resetting: the bars stay where they were, which
    // reads as paused instead of as finished.
    widget.playing ? _controller.repeat() : _controller.stop();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) => CustomPaint(
        size: const Size(14, 14),
        painter: _PlayingBarsPainter(
          phase: _controller.value,
          color: widget.color,
        ),
      ),
    );
  }
}

class _PlayingBarsPainter extends CustomPainter {
  const _PlayingBarsPainter({required this.phase, required this.color});

  final double phase;
  final Color color;

  /// Offsets so the three bars never peak together, which would read as one
  /// block going up and down.
  static const List<double> _offsets = <double>[0, 0.33, 0.66];

  @override
  void paint(Canvas canvas, Size size) {
    const double gap = 2;
    final double barWidth = (size.width - gap * 2) / 3;
    final Paint paint = Paint()..color = color;

    for (int i = 0; i < 3; i++) {
      // 0.35..1.0 of the height: never so short the bar disappears.
      final double wave =
          (math.sin((phase + _offsets[i]) * 2 * math.pi) + 1) / 2;
      final double height = size.height * (0.35 + 0.65 * wave);
      final double left = i * (barWidth + gap);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, size.height - height, barWidth, height),
          const Radius.circular(1),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_PlayingBarsPainter old) =>
      old.phase != phase || old.color != color;
}
