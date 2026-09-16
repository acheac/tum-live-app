/// TUMLive Player — a third-party client for TUM's lecture streaming service.
///
/// Talks directly to the public TUM-Live API v2 (<https://tum.live/api/v2/docs>).
/// There is no backend of our own: browsing, playback, watch progress and
/// bookmarks are all endpoints gocast already exposes. See `backend/DESIGN.md`
/// in the repository root for why, and for what a backend would eventually add.
///
/// ## Where things live
///
/// ```
/// lib/src/
///   api/        models + the HTTP client. No Flutter imports.
///   auth/       session cookie -> bearer token, and the sign-in screen.
///   home/       semester picker and course lists.
///   course/     one course's lectures.
///   player/     video playback, split into page / player / controls.
///   common/     loading and error scaffolding, formatting.
///   app_scope.dart   dependency wiring, via InheritedNotifier.
/// ```
///
/// The rule that keeps this tidy: **`api/` never imports Flutter, and widgets
/// never build URLs.** Anything that talks to TUM-Live goes through
/// [TumLiveApi]; anything that draws goes in a feature folder.
library;

import 'package:flutter/material.dart';

import 'src/api/tum_live_api.dart';
import 'src/app_scope.dart';
import 'src/auth/auth_controller.dart';
import 'src/auth/credential_store.dart';
import 'src/home/home_page.dart';

void main() => runApp(const TumLiveApp());

/// Root widget: owns the API client and the auth controller for the whole run,
/// and publishes them through [AppScope].
///
/// This is why the app is not just `runApp(MaterialApp(...))` — something has
/// to outlive every route and hold these two objects.
class TumLiveApp extends StatefulWidget {
  const TumLiveApp({super.key});

  @override
  State<TumLiveApp> createState() => _TumLiveAppState();
}

class _TumLiveAppState extends State<TumLiveApp> {
  late final AuthController _auth;
  late final TumLiveApi _api;

  /// TUM's brand blue, the same one gocast reports for its login button.
  static const Color _tumBlue = Color(0xFF3070B3);

  @override
  void initState() {
    super.initState();
    _auth = AuthController(store: SharedPreferencesCredentialStore());
    // The API client asks the auth controller for a token before every request.
    // That one line is the entire coupling between the two layers.
    _api = TumLiveApi(tokenProvider: _auth.bearerToken);
    _auth.restore();
  }

  @override
  void dispose() {
    _api.close();
    _auth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      api: _api,
      auth: _auth,
      child: MaterialApp(
        title: 'TUMLive Player',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: _tumBlue),
          cardTheme: const CardThemeData(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(12)),
            ),
          ),
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: _tumBlue,
            brightness: Brightness.dark,
          ),
          cardTheme: const CardThemeData(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(12)),
            ),
          ),
        ),
        home: ListenableBuilder(
          listenable: _auth,
          builder: (BuildContext context, Widget? child) {
            // Reading a stored session takes a round trip. Showing the home
            // screen first would flash "signed out" at a user who is not.
            if (_auth.status == AuthStatus.restoring) {
              return const _SplashScreen();
            }
            return const HomePage();
          },
        ),
      ),
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(child: CircularProgressIndicator.adaptive()),
  );
}
