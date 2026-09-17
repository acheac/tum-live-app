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
/// ```5
///
/// The rule that keeps this tidy: **`api/` never imports Flutter, and widgets
/// never build URLs.** Anything that talks to TUM-Live goes through
/// [TumLiveApi]; anything that draws goes in a feature folder.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'src/api/tum_live_api.dart';
import 'src/brand.dart';
import 'src/common/orientation.dart';
import 'src/app_scope.dart';
import 'src/auth/auth_controller.dart';
import 'src/auth/cookie_token_source.dart';
import 'src/auth/credential_store.dart';
import 'src/auth/token_source.dart';
import 'src/auth/webview_token_source.dart';
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

  @override
  void initState() {
    super.initState();
    _auth = AuthController(source: _buildTokenSource());
    // The API client asks the auth controller for a token before every request.
    // That one line is the entire coupling between the two layers.
    _api = TumLiveApi(tokenProvider: _auth.bearerToken);
    _auth.restore();
  }

  /// Picks how this platform holds a TUM-Live session.
  ///
  /// Anywhere with a WebView, the WebView's own cookie jar is the session store:
  /// the user signs in on TUM's real login page and nothing long-lived is
  /// written to our storage. Linux has no WebView implementation, so it falls
  /// back to a cookie the user fetches from a browser.
  static TokenSource _buildTokenSource() {
    if (!kIsWeb) {
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
        case TargetPlatform.iOS:
        case TargetPlatform.macOS:
        case TargetPlatform.windows:
          return WebViewTokenSource();
        case TargetPlatform.linux:
        case TargetPlatform.fuchsia:
          break;
      }
    }
    return CookieTokenSource(store: SharedPreferencesCredentialStore());
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
          colorScheme: ColorScheme.fromSeed(seedColor: tumBlue),
          cardTheme: const CardThemeData(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(12)),
            ),
          ),
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: tumBlue,
            brightness: Brightness.dark,
          ),
          cardTheme: const CardThemeData(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(12)),
            ),
          ),
        ),
        // Deliberately not gated on the session check. Public courses need no
        // authentication, and probing the session can take seconds — booting a
        // WebView, and possibly a silent SSO round trip. Blocking the UI on that
        // means a blank spinner on every launch, and a permanent one if the
        // WebView never comes up. So: show the app immediately, and let
        // restore() flip it to signed-in whenever it lands. HomePage already
        // reloads when isSignedIn changes.
        // Rotation is a screen-size decision, not a per-page one, so it is
        // settled once here for every route. Has to be inside MaterialApp:
        // MediaQuery, which it measures, does not exist above it.
        builder: (BuildContext context, Widget? child) =>
            OrientationPolicy(child: child ?? const SizedBox.shrink()),
        home: const HomePage(),
      ),
    );
  }
}
