/// Session source backed by a real WebView cookie jar.
///
/// # Why this shape
///
/// gocast's session cookie is `HttpOnly`, so JavaScript cannot read it. The
/// obvious workaround — pull it out of the platform cookie store and post it
/// ourselves — works, probably, but it depends on an assumption about each
/// platform's cookie API and leaves us storing a seven-day credential on disk.
///
/// This does something simpler: **it never touches the cookie.** A hidden
/// WebView sits on the tum.live origin, and when we need a token we ask *it* to
/// call the endpoint:
///
/// ```js
/// await fetch('/api/v2/auth/token', {method: 'POST', credentials: 'include'})
/// ```
///
/// The WebView attaches the cookie itself. We only ever see the 15-minute
/// access token that comes back. Three problems disappear at once: `HttpOnly`
/// stops mattering, nothing long-lived is written to our own storage, and the
/// cookie lives in the platform's own cookie store, inside the app's sandbox
/// container — on macOS that is `Library/Cookies/Cookies.binarycookies`. That is
/// the sandbox and file permissions protecting it, **not** the Keychain. Better
/// than a plaintext value in our own preferences, but not secret storage.
///
/// # Silent renewal
///
/// gocast's cookie is a hard 7 days with no sliding window. But the TUM identity
/// provider keeps its own, longer session, so when gocast's cookie lapses a trip
/// through `/saml/out` comes back with a fresh one and no password prompt —
/// which is exactly why a browser stays logged in to tum.live for months.
///
/// Because the cookie jar persists between launches, this source inherits that
/// behaviour: [mint] retries once through SSO before giving up. A server-side
/// auth broker could not do this — renewal needs the IdP session, and that lives
/// in a cookie jar on the user's device.
library;

import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'token_source.dart';

class WebViewTokenSource implements TokenSource {
  WebViewTokenSource({this.origin = 'https://tum.live'});

  final String origin;

  String get _host => Uri.parse(origin).host;

  HeadlessInAppWebView? _headless;
  Future<InAppWebViewController?>? _startup;
  Completer<void>? _pageLoad;

  /// How long to wait for any single navigation to settle. Kept short: this
  /// runs in the background now, but a stuck WebView should still give up
  /// rather than pin a request for half a minute.
  static const Duration _navigationTimeout = Duration(seconds: 12);

  /// How long to let a SAML round trip bounce between hosts before deciding it
  /// needs the user.
  static const Duration _ssoTimeout = Duration(seconds: 12);

  @override
  bool get supportsInteractiveLogin => true;

  /// Unlike the cookie source, this never throws on a rejected session: a
  /// WebView cannot tell "never signed in" from "session expired" — both are
  /// just a 401 — and the answer is the same either way. Null means "show the
  /// login screen".
  @override
  Future<AccessToken?> mint() async {
    final InAppWebViewController? controller = await _controller();
    if (controller == null) return null;

    final AccessToken? first = await _requestToken(controller);
    if (first != null) return first;

    // No session, or a lapsed one. If the IdP still remembers this user, a trip
    // through SSO fixes it without a prompt.
    if (await _attemptSilentSso(controller)) {
      return _requestToken(controller);
    }
    return null;
  }

  @override
  Future<void> clear() async {
    try {
      await CookieManager.instance().deleteCookies(url: WebUri(origin));
    } on Object {
      // Nothing to clean up, or the platform refused. Either way, signing out
      // locally is what matters and the caller has already done that.
    }
    // Drop back to a known page so the next mint starts from a clean document.
    final InAppWebViewController? controller =
        await _controller().timeout(_navigationTimeout, onTimeout: () => null);
    if (controller != null) {
      await _navigate(controller, origin);
    }
  }

  @override
  void dispose() {
    _headless?.dispose();
    _headless = null;
    _startup = null;
  }

  /// Boots the hidden WebView on first use and parks it on the tum.live origin.
  ///
  /// The document has to *be* on that origin for `fetch` to count as same-origin
  /// and attach the cookie, which is why this loads a real page rather than
  /// something synthetic.
  Future<InAppWebViewController?> _controller() =>
      _startup ??= _start().catchError((Object _) {
        // Let a later call try again rather than caching the failure forever.
        _startup = null;
        return null;
      });

  Future<InAppWebViewController?> _start() async {
    final Completer<void> ready = Completer<void>();
    _pageLoad = ready;

    final HeadlessInAppWebView headless = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(origin)),
      initialSettings: InAppWebViewSettings(
        // The renewal trip through SSO is navigation we never show, so let it
        // run without asking anything of the user.
        javaScriptEnabled: true,
        incognito: false,
        clearCache: false,
      ),
      onLoadStop: (InAppWebViewController controller, WebUri? url) {
        if (!(_pageLoad?.isCompleted ?? true)) _pageLoad!.complete();
      },
      onReceivedError: (_, _, _) {
        if (!(_pageLoad?.isCompleted ?? true)) _pageLoad!.complete();
      },
    );

    await headless.run();
    _headless = headless;
    await ready.future.timeout(_navigationTimeout, onTimeout: () {});
    return headless.webViewController;
  }

  /// Runs the token request inside the WebView. Null means the server said no.
  Future<AccessToken?> _requestToken(InAppWebViewController controller) async {
    final CallAsyncJavaScriptResult? result;
    try {
      result = await controller
          .callAsyncJavaScript(
            functionBody: '''
              const response = await fetch(tokenPath, {
                method: "POST",
                credentials: "include",
                headers: {"Accept": "application/json"}
              });
              if (!response.ok) return {ok: false, status: response.status};
              const body = await response.json();
              return {
                ok: true,
                token: body.access_token,
                expiresIn: body.expires_in
              };
            ''',
            arguments: <String, dynamic>{'tokenPath': '/api/v2/auth/token'},
          )
          .timeout(_navigationTimeout);
    } on Object {
      return null;
    }

    if (result == null || result.error != null) return null;
    final Object? value = result.value;
    if (value is! Map) return null;
    if (value['ok'] != true) return null;

    final Object? token = value['token'];
    if (token is! String || token.isEmpty) return null;
    final Object? expires = value['expiresIn'];
    final int seconds = expires is int ? expires : 900;

    return AccessToken(token, Duration(seconds: seconds));
  }

  /// Walks the hidden WebView through `/saml/out` and reports whether it landed
  /// back on tum.live with a session.
  ///
  /// A SAML round trip is several redirects and sometimes a JS auto-submitted
  /// form, so rather than trying to catch "the" final load, this polls the
  /// current URL until it settles somewhere meaningful.
  Future<bool> _attemptSilentSso(InAppWebViewController controller) async {
    await _navigate(controller, '$origin/saml/out');

    final DateTime deadline = DateTime.now().add(_ssoTimeout);
    while (DateTime.now().isBefore(deadline)) {
      final WebUri? current = await controller.getUrl();
      if (current != null &&
          current.host == _host &&
          !current.path.startsWith('/saml/')) {
        // Back on tum.live under our own path: the IdP let us through.
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    // Still on the identity provider — it wants the user to type something.
    return false;
  }

  Future<void> _navigate(InAppWebViewController controller, String url) async {
    final Completer<void> done = Completer<void>();
    _pageLoad = done;
    await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    await done.future.timeout(_navigationTimeout, onTimeout: () {});
  }
}
