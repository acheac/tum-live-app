/// The landing screen: pick a semester, see your courses, jump into one.
///
/// What it shows depends on whether you are signed in. Signed out, TUM-Live
/// still serves every `public` course — so the app is useful before you have
/// logged in at all, which is why browsing is not gated behind the login screen.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/tum_live_api.dart';
import '../app_scope.dart';
import '../auth/auth_controller.dart';
import '../auth/login_page.dart';
import '../common/async_builder.dart';
import '../common/course_search.dart';
import '../common/formatting.dart';
import '../common/pin_button.dart';
import '../course/course_page.dart';
import '../player/player_page.dart';

/// The one non-semester entry in the semester menu.
///
/// A sentinel rather than a bool argument, so `onSelected` can tell it apart
/// from the [Semester] values sharing the same menu.
enum _HomeView { pinned }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

/// Everything the home screen needs, fetched together.
class _HomeData {
  const _HomeData({
    required this.semesters,
    required this.semester,
    required this.live,
    required this.pinned,
    required this.enrolled,
    required this.public,
  });

  final List<Semester> semesters;
  final Semester semester;
  final List<CourseLecture> live;
  final List<Course> pinned;
  final List<Course> enrolled;
  final List<Course> public;
}

class _HomePageState extends State<HomePage> {
  Future<_HomeData>? _future;
  Semester? _semester;

  /// What the user has typed into the search field, folded on use rather than
  /// on store so the field still shows exactly what they typed.
  String _query = '';
  final TextEditingController _search = TextEditingController();

  /// How many public courses the list shows before the rotate button.
  ///
  /// Signed out a semester lists about ten to twenty courses; signed in the
  /// same endpoint also returns everything visible to a TUM account, which took
  /// SS 2024 to 75. Not about cost either way — the sliver builds only what is
  /// on screen — but 75 rows is a wall to scroll past, and the landing screen
  /// should be a handful of suggestions.
  static const int _publicPageSize = 5;

  /// Which group of [_publicPageSize] is showing, counted from the top of the
  /// shuffled list. The rotate button advances it.
  int _publicPage = 0;

  /// Whether the page is showing the pinned courses instead of everything.
  ///
  /// A mode rather than a pushed route: the semester picker and the search
  /// field belong to both views, and pushing a page would either duplicate
  /// them or leave the pinned list without a way to be searched. Everything
  /// else is hidden while it is on, so it reads as its own screen.
  bool _showPinned = false;

  /// Tracks the sign-in state the current data was loaded under, so signing in
  /// or out refreshes the page instead of showing stale lists.
  bool? _loadedSignedIn;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool signedIn = AppScope.authOf(context).isSignedIn;
    if (_loadedSignedIn != signedIn) {
      _loadedSignedIn = signedIn;
      _future = _load();
    }
  }

  Future<_HomeData> _load() async {
    final TumLiveApi api = AppScope.apiOf(context);
    final AuthController auth = AppScope.authOf(context);

    final SemesterList semesters = await api.getSemesters();
    final Semester semester =
        _semester ??
        semesters.current ??
        (semesters.semesters.isNotEmpty
            ? semesters.semesters.first
            : const Semester(year: 2025, teachingTerm: 'W'));
    _semester = semester;

    // These are independent, so run them together rather than in sequence.
    final List<Object> results = await Future.wait(<Future<Object>>[
      _safe(api.getLiveCourses(), const <CourseLecture>[]),
      _safe(api.getPublicCourses(semester), const <Course>[]),
      if (auth.isSignedIn) ...<Future<Object>>[
        _safe(api.getPinnedCourses(), const <Course>[]),
        _safe(api.getEnrolledCourses(semester), const <Course>[]),
      ],
    ]);

    return _HomeData(
      semesters: _realSemesters(semesters.semesters),
      semester: semester,
      live: results[0] as List<CourseLecture>,
      // Shuffled once here, not on every build: the first group the user
      // lands on is a different five each visit, but it must not reshuffle
      // under them as they type in the search field. A pull-to-refresh
      // re-runs this and deals a new order.
      public: _shuffled(results[1] as List<Course>),
      pinned: results.length > 2 ? results[2] as List<Course> : const <Course>[],
      enrolled: results.length > 3
          ? results[3] as List<Course>
          : const <Course>[],
    );
  }

  /// Keeps one failing section from blanking the whole screen.
  ///
  /// The semester list is the only genuinely required call; everything else can
  /// come back empty and the page still makes sense.
  Future<T> _safe<T>(Future<T> future, T fallback) =>
      future.catchError((Object _) => fallback);

  /// Re-runs the request behind [_future].
  ///
  /// The body must be a block, not an arrow. `setState(() => _future = _load())`
  /// returns the assignment's value — a Future — and setState rejects a callback
  /// that returns one.
  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  void _pickSemester(Semester semester) {
    setState(() {
      _semester = semester;
      // Leave the pinned view. `/courses/pinned` takes no semester, so staying
      // in it would swallow the choice: the label would read the new term
      // while the same semester-less list sat underneath, and picking a
      // semester would look like it did nothing.
      _showPinned = false;
      _future = _load();
    });
  }

  /// A cross-fade to the login page, in place of the platform's slide.
  ///
  /// The page it opens is mostly an Android WebView, and a platform view does
  /// not slide with the route it is in — it lags the Flutter content around it
  /// and arrives with a visible snap. Fading moves nothing, so there is nothing
  /// for it to fall behind.
  Route<void> _loginRoute() => PageRouteBuilder<void>(
    transitionDuration: const Duration(milliseconds: 260),
    reverseTransitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (_, _, _) => const LoginPage(),
    transitionsBuilder:
        (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondary,
          Widget child,
        ) => FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: child,
        ),
  );

  Future<void> _openLogin() async {
    await Navigator.of(context).push(_loginRoute());
    // didChangeDependencies picks up the change; this covers a cancelled login
    // where the status never changed but the user may still expect a refresh.
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    // The pinned list is its own request, so pinning a course on another page
    // leaves this one showing what it fetched on launch. See [pinRevision].
    pinRevision.addListener(_reload);
  }

  @override
  void dispose() {
    pinRevision.removeListener(_reload);
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AuthController auth = AppScope.authOf(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('TUMLive'),
        actions: <Widget>[
          if (auth.isSignedIn)
            PopupMenuButton<String>(
              tooltip: auth.user?.displayName ?? 'Account',
              icon: const Icon(Icons.account_circle),
              onSelected: (String value) {
                if (value == 'signout') auth.signOut();
              },
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                PopupMenuItem<String>(
                  enabled: false,
                  child: Text(auth.user?.displayName ?? 'Signed in'),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem<String>(
                  value: 'signout',
                  child: Text('Sign out'),
                ),
              ],
            ),
        ],
      ),
      body: AsyncBuilder<_HomeData>(
        future: _future,
        onRetry: _reload,
        builder: (BuildContext context, _HomeData data) =>
            RefreshIndicator(
              onRefresh: () async => _reload(),
              child: _buildBody(context, data, auth),
            ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, _HomeData data, AuthController auth) {
    // Ids rather than Course.pinned: the flag is only reliable on whatever
    // endpoint the server chose to set it on, while the pinned list itself is
    // definitive for every course on the page.
    final Set<int> pinnedIds = data.pinned.map((Course c) => c.id).toSet();

    if (_showPinned) return _buildPinnedView(data, pinnedIds);

    // `/courses/live` is every stream running anywhere on TUM-Live, which in
    // term is a great many lectures the user has nothing to do with — and this
    // section sits above everything else on the page. Signed in, narrow it to
    // their own courses: enrolled or pinned.
    //
    // Signed out there is no "their own" to narrow to, and anything live that
    // a signed-out user can see is public by definition, so it is left alone
    // rather than emptied.
    final Set<int> mine = <int>{
      ...data.enrolled.map((Course c) => c.id),
      ...pinnedIds,
    };
    // Every list is filtered, not just the public one. A query is the user
    // saying "find me this course", and it would be odd for a match to be
    // hidden because the course happens to be one of their own.
    final List<CourseLecture> live = data.live
        .where(
          (CourseLecture l) =>
              !auth.isSignedIn || mine.contains(l.course.id),
        )
        .where(
          (CourseLecture l) =>
              searchCourses(<Course>[l.course], _query).isNotEmpty,
        )
        .toList();
    final List<Course> enrolled = searchCourses(data.enrolled, _query);
    final List<Course> public = searchCourses(data.public, _query);
    // The cap applies to browsing, not to searching.
    final bool showingWindow = _query.trim().isEmpty;
    // Pinned courses are deliberately not part of this. They are in the
    // semester menu now, not in a section, and the menu is navigation rather
    // than search results — it lists them whatever is typed. Counting them
    // here would report a match the page never shows.
    final bool nothingMatched =
        _query.trim().isNotEmpty &&
        live.isEmpty &&
        enrolled.isEmpty &&
        public.isEmpty;

    final List<Widget> slivers = <Widget>[
      SliverToBoxAdapter(child: _buildSemesterBar(data)),
      SliverToBoxAdapter(child: _buildSearchField()),
      if (nothingMatched)
        SliverToBoxAdapter(child: _buildNoMatches())
      else ...<Widget>[
        if (live.isNotEmpty) ...<Widget>[
          const _SectionHeader('Live now', icon: Icons.sensors),
          SliverList.builder(
            itemCount: live.length,
            itemBuilder: (BuildContext context, int i) {
              final CourseLecture now = live[i];
              return _CourseTile(
                course: now.course,
                subtitle: 'Live: ${now.lecture.displayName}',
                highlight: true,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => PlayerPage(
                      courseSlug: now.course.slug,
                      lectureId: now.lecture.id,
                      courseName: now.course.name,
                    ),
                  ),
                ),
              );
            },
          ),
        ],
        if (auth.isSignedIn) ...<Widget>[
          const _SectionHeader('My courses', icon: Icons.school_outlined),
          if (enrolled.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 24,
                ),
                child: Text(
                  _query.trim().isEmpty
                      ? 'No enrolled courses in this semester.'
                      : 'None of your courses match.',
                ),
              ),
            )
          else
            _courseSliver(enrolled, pinnedIds),
        ] else
          SliverToBoxAdapter(child: _buildSignInHint(context)),
        _SectionHeader(
          'Public courses',
          icon: Icons.public,
          // Only when there is a next group to go to, and never while
          // searching: a query is the user asking for specific courses, and
          // hiding matches behind a rotate button is the one thing search
          // must not do.
          trailing: showingWindow && public.length > _publicPageSize
              ? _buildRotateButton(public.length)
              : null,
        ),
        if (public.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
              child: Text(
                _query.trim().isEmpty
                    ? 'No public courses in this semester.'
                    : 'No public courses match.',
              ),
            ),
          )
        else
          _courseSliver(
            showingWindow ? _publicWindow(public) : public,
            pinnedIds,
          ),
      ],
      const SliverToBoxAdapter(child: SizedBox(height: 32)),
    ];

    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: slivers,
    );
  }

  Widget _courseSliver(List<Course> courses, Set<int> pinnedIds) =>
      SliverList.builder(
        itemCount: courses.length,
        itemBuilder: (BuildContext context, int i) {
          final Course course = courses[i];
          return _CourseTile(
            course: course,
            subtitle: _courseSubtitle(course),
            isPinned: pinnedIds.contains(course.id),
            onTap: () => _openCourse(course),
          );
        },
      );

  /// The pinned courses on their own, with the search field still filtering.
  ///
  /// Live, enrolled and public are all left out: the field searches whatever
  /// the page is showing, so leaving them in would quietly widen a search the
  /// user made from inside the pinned list.
  Widget _buildPinnedView(_HomeData data, Set<int> pinnedIds) {
    final List<Course> pinned = searchCourses(data.pinned, _query);
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: <Widget>[
        SliverToBoxAdapter(child: _buildSemesterBar(data)),
        SliverToBoxAdapter(child: _buildSearchField()),
        const _SectionHeader('Pinned courses', icon: Icons.push_pin),
        if (pinned.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 24,
              ),
              child: Text(
                _query.trim().isEmpty
                    ? 'No pinned courses yet. Open a course and tap the pin.'
                    : 'No pinned courses match.',
              ),
            ),
          )
        else
          _courseSliver(pinned, pinnedIds),
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }

  String _courseSubtitle(Course course) {
    final Lecture? last = course.lastRecording;
    if (last != null && last.start != null) {
      return 'Last lecture ${formatLectureDate(last.start)}';
    }
    final Lecture? next = course.nextLecture;
    if (next != null && next.start != null) {
      return 'Next lecture ${formatLectureDate(next.start)}';
    }
    return formatSemester(course.semester.year, course.semester.teachingTerm);
  }

  /// The semesters worth offering, which is not all of them.
  ///
  /// `/semesters` ends its list with `S 1970` and `W 23` — an epoch default and
  /// a two-digit year that never parsed. Neither has ever had a course, and
  /// both sit at the bottom of the picker where they read as real terms. The
  /// cutoff is deliberately loose: anything before TUM-Live existed is a data
  /// artefact, and a real term appearing after 2000 will always pass.
  static List<Semester> _realSemesters(List<Semester> all) =>
      all.where((Semester s) => s.year >= 2000).toList();

  /// A copy of [courses] in random order.
  ///
  /// Copied rather than shuffled in place: the list comes from the API layer
  /// and nothing there expects a caller to reorder it.
  static List<Course> _shuffled(List<Course> courses) {
    final List<Course> copy = List<Course>.of(courses);
    copy.shuffle();
    return copy;
  }

  /// The slice of [courses] the rotate button has landed on.
  ///
  /// Non-overlapping groups rather than a random draw each press: a draw can
  /// repeat what was just on screen, and "another five" should mean five you
  /// have not seen. Cycling in order guarantees that, and walks the whole list
  /// before it comes back round. The last group is short whenever the count is
  /// not a multiple of [_publicPageSize] — 12 courses rotate 5, 5, 2 — which
  /// is the honest thing to show rather than padding it from the start again.
  List<Course> _publicWindow(List<Course> courses) {
    if (courses.length <= _publicPageSize) return courses;
    final int pages = (courses.length / _publicPageSize).ceil();
    final int start = (_publicPage % pages) * _publicPageSize;
    return courses.sublist(
      start,
      math.min(start + _publicPageSize, courses.length),
    );
  }

  /// Filters every list on this page by name.
  ///
  /// Filtering in state rather than re-fetching: one semester is at most a few
  /// dozen courses and they are already in memory, so there is nothing to ask
  /// the server for and no reason to make typing wait on the network.
  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: TextField(
        key: const ValueKey<String>('course-search'),
        controller: _search,
        textInputAction: TextInputAction.search,
        onChanged: (String value) => setState(() => _query = value),
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search courses',
          prefixIcon: const Icon(Icons.search, size: 20),
          // Only once there is something to clear, so the field is not sitting
          // there offering to undo nothing.
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  key: const ValueKey<String>('course-search-clear'),
                  icon: const Icon(Icons.clear, size: 20),
                  tooltip: 'Clear',
                  onPressed: () {
                    _search.clear();
                    setState(() => _query = '');
                  },
                ),
          border: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
        ),
      ),
    );
  }

  /// Advances the public list to the next group of [_publicPageSize].
  ///
  /// Labelled with the range rather than just an icon, because a button that
  /// silently swaps five rows for five others gives no clue that the rest of
  /// the semester is reachable at all, or that pressing again keeps going.
  Widget _buildRotateButton(int total) {
    final int pages = (total / _publicPageSize).ceil();
    final int start = (_publicPage % pages) * _publicPageSize;
    final int last = math.min(start + _publicPageSize, total);
    return TextButton.icon(
      key: const ValueKey<String>('public-rotate'),
      onPressed: () => setState(() => _publicPage++),
      icon: const Icon(Icons.refresh, size: 18),
      label: Text('${start + 1}–$last of $total'),
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
    );
  }

  /// Shown in place of every section when a query matches nothing at all.
  ///
  /// Names the semester: the commonest reason for no matches is looking for a
  /// course that exists, in a term that is not the one selected.
  Widget _buildNoMatches() {
    final Semester? semester = _semester;
    final String where = semester == null
        ? 'this semester'
        : formatSemester(semester.year, semester.teachingTerm);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
      child: Column(
        children: <Widget>[
          const Icon(Icons.search_off, size: 40),
          const SizedBox(height: 12),
          Text(
            'Nothing in $where matches "${_query.trim()}".',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            'Try another semester.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  /// The semester picker, which also carries the pinned courses.
  ///
  /// One menu for two kinds of thing, which is unusual enough to justify: the
  /// pinned list had a full-width section of its own, and a section header plus
  /// its rows is a lot of the first screen spent on a list that is usually two
  /// or three courses long. Folded in here it costs nothing until opened.
  ///
  /// A [PopupMenuButton] rather than the [DropdownButton] this replaced,
  /// because a dropdown's label *is* its selection: picking a pinned course
  /// would leave the course's name sitting where the semester belongs. A popup
  /// keeps its own label and lets the entries mean different things —
  /// semesters switch the page, courses open.
  Widget _buildSemesterBar(_HomeData data) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
      child: Row(
        children: <Widget>[
          PopupMenuButton<Object>(
            key: const ValueKey<String>('semester-menu'),
            // Sixteen semesters plus the pinned entry is taller than a phone,
            // and a menu that cannot fit under its button gets moved somewhere
            // it does fit — it opens shifted up the screen and away from the
            // thing that was tapped. Bounding it keeps it anchored and turns
            // the overflow into a scroll. Half the window rather than a fixed
            // number of rows, so a large system font scrolls sooner instead of
            // reintroducing the jump.
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height / 2,
            ),
            // The pinned entry is always offered, whether or not anything is
            // pinned — it is how the empty state gets explained.
            tooltip: 'Semester and pinned courses',
            position: PopupMenuPosition.under,
            onSelected: (Object value) {
              if (value is Semester) {
                _pickSemester(value);
              } else if (value == _HomeView.pinned) {
                setState(() {
                  _showPinned = !_showPinned;
                  // Both ways. The field filters whatever the page is showing,
                  // so a query typed against one list means nothing against
                  // the other — carrying it over lands the user in a view
                  // already filtered by something they did not ask for here,
                  // and an empty result they did not cause.
                  //
                  // Deliberately not done when picking a semester: hunting the
                  // same course across terms is a real thing to want, and the
                  // query still means the same there.
                  _search.clear();
                  _query = '';
                });
              }
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<Object>>[
              // One entry, not one per course: the courses have a view of
              // their own now, and a menu that listed them as well would be
              // two ways to reach the same place.
              PopupMenuItem<Object>(
                value: _HomeView.pinned,
                child: Row(
                  children: <Widget>[
                    Icon(
                      _showPinned ? Icons.school_outlined : Icons.push_pin,
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Text(_showPinned ? 'My courses' : 'Pinned courses'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              for (final Semester s in data.semesters)
                PopupMenuItem<Object>(
                  value: s,
                  child: Text(formatSemester(s.year, s.teachingTerm)),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.calendar_today_outlined, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    formatSemester(
                      data.semester.year,
                      data.semester.teachingTerm,
                    ),
                  ),
                  const Icon(Icons.arrow_drop_down),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Opens [course]'s lecture list. Shared by the course rows and the menu.
  void _openCourse(Course course) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CoursePage(
          slug: course.slug,
          semester: course.semester,
          courseName: course.name,
        ),
      ),
    );
  }

  Widget _buildSignInHint(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          leading: const Icon(Icons.login),
          title: const Text('Sign in to see your own courses'),
          subtitle: const Text(
            'Enrolled courses and watch progress need a TUM-Live session.',
          ),
          onTap: _openLogin,
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title, {this.icon, this.trailing});

  final String title;
  final IconData? icon;

  /// Pushed to the far end of the row. Used by the public-courses header to
  /// carry its rotate button, so the button reads as part of the section
  /// rather than as a row in the list.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Row(
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(
                icon,
                size: 18,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
            ],
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (trailing != null) ...<Widget>[
              const Spacer(),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

class _CourseTile extends StatelessWidget {
  const _CourseTile({
    required this.course,
    required this.subtitle,
    required this.onTap,
    this.highlight = false,
    this.isPinned = false,
  });

  final Course course;
  final String subtitle;
  final VoidCallback onTap;
  final bool highlight;

  /// Draws a small pin over the chevron. Read from the pinned list rather than
  /// from `course.pinned`, which is only set on some endpoints.
  final bool isPinned;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Card(
        margin: EdgeInsets.zero,
        color: highlight ? theme.colorScheme.errorContainer : null,
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: highlight
                ? theme.colorScheme.error
                : theme.colorScheme.primaryContainer,
            child: Icon(
              highlight ? Icons.sensors : Icons.play_arrow,
              color: highlight
                  ? theme.colorScheme.onError
                  : theme.colorScheme.onPrimaryContainer,
            ),
          ),
          title: Text(
            course.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          // Stacked, not side by side: a second trailing icon on its own
          // would eat width from titles that already wrap to two lines.
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (isPinned)
                Icon(
                  Icons.push_pin,
                  size: 14,
                  color: theme.colorScheme.primary,
                ),
              const Icon(Icons.chevron_right),
            ],
          ),
          onTap: onTap,
        ),
      ),
    );
  }
}
