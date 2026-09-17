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
import '../brand.dart';
import 'sso_cover.dart';

class WebViewLoginPage extends StatefulWidget {
  const WebViewLoginPage({super.key});

  @override
  State<WebViewLoginPage> createState() => _WebViewLoginPageState();
}

class _WebViewLoginPageState extends State<WebViewLoginPage> {
  double _progress = 0;
  String? _error;

  /// True whenever the browser is on our own origin.
  ///
  /// Everything TUM-Live serves is covered, `/saml/` handshake pages included.
  /// Those render the website for the moment they are on screen, which is the
  /// flash this exists to stop — it is not only the final landing page that
  /// shows through. The only pages ever revealed are the identity provider's,
  /// because those are the only ones the user has anything to do on.
  ///
  /// The WebView stays mounted and loading underneath; this just sits on top.
  bool _finishing = true;

  /// True once the browser has reached the identity provider.
  ///
  /// The first load is `/saml/out` on our own origin, so the cover is up before
  /// the user has done anything, and "Signing you in" would be a lie at that
  /// point. Only the trip back deserves those words.
  bool _reachedIdp = false;

  /// Shown when a load lands back on tum.live but there is still no session.
  ///
  /// The common cause is TUM's consent step: the user authenticated, but did not
  /// confirm the release, so gocast never started a session. Without this the
  /// page just sits there looking hung.
  bool _noSessionYet = false;

  /// True while a session check is in flight. SAML bounces through several
  /// loads, and without this every one of them would start its own check.
  bool _checking = false;

  /// Set once sign-in has succeeded, to take the WebView out of the tree before
  /// this route pops.
  ///
  /// The cover is a Flutter widget; the WebView is an Android platform view.
  /// While the route animates away the two stop agreeing about z-order, and
  /// the web page draws over the cover — which is why the flash appeared on the
  /// *home* screen, under the home app bar, after this page was supposedly
  /// gone. Nothing composited over a platform view can be relied on through a
  /// route transition, so the platform view has to be gone before the
  /// transition starts.
  bool _closing = false;

  /// Held so back can take focus off a web text field: the keyboard belongs to
  /// the native WebView, so Flutter's own focus tree cannot put it away.
  InAppWebViewController? _webController;

  late final AuthController _auth = AppScope.authOf(context);
  late final String _host = Uri.parse(_auth.origin).host;

  /// Whether [url] is the post-login landing on our own origin.
  bool _isLanding(WebUri? url) =>
      url != null && url.host == _host && !url.path.startsWith('/saml/');

  /// Keeps the cover in step with wherever the browser has gone.
  ///
  /// Driven from the start of a navigation, not the end, so the page is hidden
  /// before it has a chance to draw.
  void _syncCover(WebUri? url) {
    if (!mounted || url == null) return;
    final bool cover = coverForUrl(
      url: url,
      ownHost: _host,
      noSessionYet: _noSessionYet,
      covered: _finishing,
    );
    // Away from our origin means the identity provider, which the user has to
    // see. Remembered so the cover can stop saying "opening" once they are on
    // their way back.
    final bool reached = _reachedIdp || url.host != _host;
    if (cover == _finishing && reached == _reachedIdp) return;
    setState(() {
      _finishing = cover;
      _reachedIdp = reached;
    });
  }

  /// After any navigation that lands back on tum.live, see whether a session
  /// exists yet. Checking the session beats guessing the final URL — gocast can
  /// land the user on the home page, a course, or wherever they came from.
  Future<void> _maybeFinish(WebUri? url) async {
    if (_checking || !mounted || url == null) return;
    // Still at the identity provider, or mid-handshake. Any hint from an
    // earlier attempt belongs to a page the user has now left.
    if (!_isLanding(url)) {
      if (_noSessionYet) setState(() => _noSessionYet = false);
      return;
    }
    if (!_finishing) setState(() => _finishing = true);

    _checking = true;
    try {
      await _auth.refreshSession();
      if (!mounted) return;
      if (_auth.isSignedIn) {
        // Drop the WebView, let that frame land, and only then pop. Popping in
        // the same frame leaves the platform view alive for the whole
        // transition, which is the flash this avoids.
        setState(() => _closing = true);
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
        Navigator.of(context).pop(true);
        return;
      }
      // Back on tum.live with nothing to show for it. Say so, rather than
      // leaving the user staring at a page that looks finished, and uncover the
      // WebView so they can act on whatever TUM is still showing.
      setState(() {
        _noSessionYet = true;
        _finishing = false;
      });
    } finally {
      _checking = false;
    }
  }

  /// Back, while the keyboard is up, should put the keyboard away — not abandon
  /// a half-typed login.
  ///
  /// Android only raises this for us inconsistently: dismissing the keyboard
  /// happens by itself for some fields but not others, and where it does not,
  /// the gesture falls through and pops the route. Handling it here makes every
  /// field behave the same, and a second back still leaves the page.
  void _handleBack(bool didPop) {
    if (didPop || !mounted) return;
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      _webController?.clearFocus();
      FocusManager.instance.primaryFocus?.unfocus();
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) =>
          _handleBack(didPop),
      child: _buildScaffold(context),
    );
  }

  Widget _buildScaffold(BuildContext context) {
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
      body: _error != null
          ? _buildError(context)
          : Stack(
              children: <Widget>[
                Column(
                  children: <Widget>[
                    // Always up, for the whole visit. The checkbox sits on a
                    // page we do not control and can appear after any redirect,
                    // so there is no moment where hiding this is safe.
                    if (_noSessionYet)
                      _buildNoSessionHint(context)
                    else
                      _buildStaySignedInTip(context),
                    // Replaced rather than hidden: a platform view that is
                    // still in the tree still draws, whatever is stacked over
                    // it.
                    Expanded(
                      child: _closing
                          ? const SizedBox.expand()
                          : _buildWebView(),
                    ),
                  ],
                ),
                // Opaque, and above the WebView rather than replacing it: the
                // page has to keep loading for the session to land.
                // Cross-faded rather than switched. The cover goes up and
                // down several times in one sign-in — out to the identity
                // provider, back for each SAML hop — and as a hard cut each of
                // those reads as a flicker, which is what made the flow feel
                // abrupt even once nothing was leaking through.
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: !(_finishing || _closing),
                    child: AnimatedOpacity(
                      opacity: (_finishing || _closing) ? 1 : 0,
                      // Asymmetric on purpose. Covering has to be instant —
                      // fading in over a live page would show that page
                      // through the cover for the length of the fade, which is
                      // a slower version of the flash this is all here to
                      // stop. Uncovering has nothing to hide, so it can take
                      // its time and hand the login page over gently.
                      duration: Duration(
                        milliseconds: (_finishing || _closing) ? 0 : 220,
                      ),
                      curve: Curves.easeOut,
                      child: _buildFinishing(context),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildWebView() {
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(_auth.ssoUrl.toString())),
      onWebViewCreated: (InAppWebViewController controller) =>
          _webController = controller,
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
      onLoadStart: (_, WebUri? url) => _syncCover(url),
      // Some of the handshake moves without a page load at all, and a cover
      // driven only by onLoadStart would miss those.
      onUpdateVisitedHistory: (_, WebUri? url, _) => _syncCover(url),
      onLoadStop: (_, WebUri? url) => _maybeFinish(url),
      onReceivedError: (_, _, WebResourceError error) {
        if (mounted) setState(() => _error = error.description);
      },
    );
  }

  /// The one thing the user has to get right, in TUM's own blue.
  ///
  /// Fixed rather than themed: this sits directly above TUM's login page, so it
  /// should read as part of it in either theme, and the arrow points at the
  /// checkbox it is talking about. Weight and size carry the urgency here —
  /// a full-bleed warning yellow shouted louder than this deserves.
  Widget _buildStaySignedInTip(BuildContext context) {
    return Material(
      color: tumBlue,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Icon(Icons.check_box_outlined, size: 28, color: onTumBlue),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    // Quoted exactly as TUM's IdP renders it, so it can be
                    // matched by eye. The label follows the WebView's locale,
                    // hence both: `keep me logged in` / `angemeldet bleiben`.
                    Text(
                      'Tick "keep me logged in"',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: onTumBlue,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Shown as "angemeldet bleiben" in German. Without that '
                      'checkbox TUM hands back no session cookie, and the app '
                      'cannot sign you in.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: onTumBlue,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.south_rounded, size: 26, color: onTumBlue),
            ],
          ),
        ),
      ),
    );
  }

  /// The loading screen that stands in for the web page.
  ///
  /// Fully opaque: it is faded in and out over a live WebView, and anything
  /// translucent would show the page through it mid-fade — the very thing the
  /// cover exists to prevent.
  Widget _buildFinishing(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            Text(
              _reachedIdp ? 'Signing you in…' : 'Opening TUM login…',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoSessionHint(BuildContext context) {
    return Material(
      color: tumBlue,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Icon(Icons.check_box_outlined, size: 24, color: onTumBlue),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Still not signed in — "keep me logged in" ("angemeldet '
                'bleiben") was almost certainly left unticked. Sign in again '
                'and tick it. This closes by itself once it works.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: onTumBlue,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
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
