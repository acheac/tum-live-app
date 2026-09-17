/// When the sign-in WebView should be hidden behind the loading screen.
///
/// Pure Dart, and a file of its own, for one reason: `InAppWebView` needs a
/// platform view, so the login page cannot be pumped under `flutter test` and
/// the rule would otherwise be untestable. It is also the whole of the
/// behaviour — the rest of that page is plumbing around it.
library;

/// Whether the cover belongs over [url].
///
/// Everything on [ownHost] is covered, `/saml/` handshake pages included: they
/// are served by TUM-Live and render its website for as long as they are on
/// screen, so covering only the final landing page still lets the site flash
/// up. The identity provider's own pages are the only ones ever shown, because
/// they are the only ones with anything for the user to do.
///
/// [noSessionYet] is the exception. It means the browser came back to
/// [ownHost] without a session — TUM's consent step, usually — and the page was
/// deliberately uncovered so the user could act on it. While that is true the
/// cover stays as it is ([covered]) rather than dropping back over a page
/// somebody is reading.
bool coverForUrl({
  required Uri url,
  required String ownHost,
  required bool noSessionYet,
  required bool covered,
}) {
  if (url.host != ownHost) return false;
  return noSessionYet ? covered : true;
}
