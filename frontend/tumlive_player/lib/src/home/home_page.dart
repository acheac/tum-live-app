/// The landing screen: pick a semester, see your courses, jump into one.
///
/// What it shows depends on whether you are signed in. Signed out, TUM-Live
/// still serves every `public` course — so the app is useful before you have
/// logged in at all, which is why browsing is not gated behind the login screen.
library;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/tum_live_api.dart';
import '../app_scope.dart';
import '../auth/auth_controller.dart';
import '../auth/login_page.dart';
import '../common/async_builder.dart';
import '../common/formatting.dart';
import '../course/course_page.dart';
import '../player/player_page.dart';

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
      semesters: semesters.semesters,
      semester: semester,
      live: results[0] as List<CourseLecture>,
      public: results[1] as List<Course>,
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

  void _reload() => setState(() => _future = _load());

  void _pickSemester(Semester semester) {
    setState(() {
      _semester = semester;
      _future = _load();
    });
  }

  Future<void> _openLogin() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const LoginPage()),
    );
    // didChangeDependencies picks up the change; this covers a cancelled login
    // where the status never changed but the user may still expect a refresh.
    if (mounted) setState(() {});
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
            )
          else
            TextButton.icon(
              onPressed: _openLogin,
              icon: const Icon(Icons.login),
              label: const Text('Sign in'),
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
    final List<Widget> slivers = <Widget>[
      SliverToBoxAdapter(child: _buildSemesterBar(data)),
      if (data.live.isNotEmpty) ...<Widget>[
        const _SectionHeader('Live now', icon: Icons.sensors),
        SliverList.builder(
          itemCount: data.live.length,
          itemBuilder: (BuildContext context, int i) {
            final CourseLecture live = data.live[i];
            return _CourseTile(
              course: live.course,
              subtitle: 'Live: ${live.lecture.displayName}',
              highlight: true,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PlayerPage(
                    courseSlug: live.course.slug,
                    lectureId: live.lecture.id,
                    courseName: live.course.name,
                  ),
                ),
              ),
            );
          },
        ),
      ],
      if (data.pinned.isNotEmpty) ...<Widget>[
        const _SectionHeader('Pinned', icon: Icons.push_pin_outlined),
        _courseSliver(data.pinned),
      ],
      if (auth.isSignedIn) ...<Widget>[
        const _SectionHeader('My courses', icon: Icons.school_outlined),
        if (data.enrolled.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 24),
              child: Text('No enrolled courses in this semester.'),
            ),
          )
        else
          _courseSliver(data.enrolled),
      ] else
        SliverToBoxAdapter(child: _buildSignInHint(context)),
      const _SectionHeader('Public courses', icon: Icons.public),
      if (data.public.isEmpty)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: Text('No public courses in this semester.'),
          ),
        )
      else
        _courseSliver(data.public),
      const SliverToBoxAdapter(child: SizedBox(height: 32)),
    ];

    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: slivers,
    );
  }

  Widget _courseSliver(List<Course> courses) => SliverList.builder(
    itemCount: courses.length,
    itemBuilder: (BuildContext context, int i) {
      final Course course = courses[i];
      return _CourseTile(
        course: course,
        subtitle: _courseSubtitle(course),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => CoursePage(
              slug: course.slug,
              semester: course.semester,
              courseName: course.name,
            ),
          ),
        ),
      );
    },
  );

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

  Widget _buildSemesterBar(_HomeData data) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: <Widget>[
          const Icon(Icons.calendar_today_outlined, size: 18),
          const SizedBox(width: 8),
          DropdownButton<Semester>(
            value: data.semesters.contains(data.semester)
                ? data.semester
                : null,
            hint: Text(
              formatSemester(
                data.semester.year,
                data.semester.teachingTerm,
              ),
            ),
            underline: const SizedBox.shrink(),
            items: <DropdownMenuItem<Semester>>[
              for (final Semester s in data.semesters)
                DropdownMenuItem<Semester>(
                  value: s,
                  child: Text(formatSemester(s.year, s.teachingTerm)),
                ),
            ],
            onChanged: (Semester? s) {
              if (s != null) _pickSemester(s);
            },
          ),
        ],
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
  const _SectionHeader(this.title, {this.icon});

  final String title;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Row(
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
            ],
            Text(title, style: Theme.of(context).textTheme.titleMedium),
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
  });

  final Course course;
  final String subtitle;
  final VoidCallback onTap;
  final bool highlight;

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
          title: Text(course.name, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right),
          onTap: onTap,
        ),
      ),
    );
  }
}
