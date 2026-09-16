/// Interactive sign-in: TUM's own login page, shown inside the app.
///
/// The app never sees the password. It renders TUM-Live's SSO flow in a WebView,
/// the user authenticates against the real identity provider, and the resulting
/// session cookie lands in the WebView's own jar — where [WebViewTokenSource]
/// can use it without ever reading it.
///
/// This is the whole reason not to build a username/password form: the user gets
/// the same "type my ID and password in the app" experience, but the credentials
/// go to TUM and nowhere else.
library;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../app_scope.dart';
import '../auth/auth_controller.dart';

class WebViewLoginPage extends StatefulWidget {
  const WebViewLoginPage({super.key});

  @override
  State<WebViewLoginPage> createState() => _WebViewLoginPageState();
}

class _WebViewLoginPageState extends State<WebViewLoginPage> {
  double _progress = 0;
  String? _error;

  /// True while a session check is in flight. SAML bounces through several
  /// loads, and without this every one of them would start its own check.
  bool _checking = false;

  late final AuthController _auth = AppScope.authOf(context);
  late final String _host = Uri.parse(_auth.origin).host;

  /// After any navigation that lands back on tum.live, see whether a session
  /// exists yet. Checking the session beats guessing the final URL — gocast can
  /// land the user on the home page, a course, or wherever they came from.
  Future<void> _maybeFinish(WebUri? url) async {
    if (_checking || !mounted || url == null) return;
    // Still at the identity provider, or mid-handshake.
    if (url.host != _host || url.path.startsWith('/saml/')) return;

    _checking = true;
    try {
      await _auth.refreshSession();
      if (!mounted) return;
      if (_auth.isSignedIn) {
        Navigator.of(context).pop(true);
      }
    } finally {
      _checking = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sign in with TUM'),
        bottom: _progress < 1
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(value: _progress, minHeight: 2),
              )
            : null,
      ),
      body: _error != null ? _buildError(context) : _buildWebView(),
    );
  }

  Widget _buildWebView() {
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(_auth.ssoUrl.toString())),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        // Must share the jar with the headless view that mints tokens, so
        // signing in here leaves a session the rest of the app can use.
        incognito: false,
        transparentBackground: true,
      ),
      onProgressChanged: (_, int progress) {
        if (mounted) setState(() => _progress = progress / 100);
      },
      onLoadStop: (_, WebUri? url) => _maybeFinish(url),
      onReceivedError: (_, _, WebResourceError error) {
        if (mounted) setState(() => _error = error.description);
      },
    );
  }

  Widget _buildError(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.cloud_off,
              size: 40,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              'Could not load the TUM login page.\n$_error',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 20),
            FilledButton.tonalIcon(
              onPressed: () => setState(() {
                _error = null;
                _progress = 0;
              }),
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}
