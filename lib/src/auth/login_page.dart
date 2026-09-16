/// Picks the right sign-in screen for this platform.
///
/// Two flows exist, and which one applies is decided by the [TokenSource] the
/// app was built with, not by checking the platform here:
///
///  * [WebViewLoginPage] — TUM's real login page inside the app. Used wherever
///    a WebView exists, which is everywhere except Linux.
///  * [CookieLoginPage] — the user fetches a session cookie from a browser.
///
/// There is deliberately no username/password form. TUM-Live authenticates over
/// SAML, so one would not work; and the TUM password unlocks far more than
/// lecture recordings, so it belongs only in TUM's own login page.
library;

import 'package:flutter/material.dart';

import '../app_scope.dart';
import 'cookie_login_page.dart';
import 'webview_login_page.dart';

class LoginPage extends StatelessWidget {
  const LoginPage({super.key});

  @override
  Widget build(BuildContext context) =>
      AppScope.authOf(context).supportsInteractiveLogin
      ? const WebViewLoginPage()
      : const CookieLoginPage();
}
