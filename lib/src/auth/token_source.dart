/// Where short-lived access tokens come from.
///
/// TUM-Live has two credentials, and this is the seam between them:
///
///  * a **session**, long-lived (gocast issues a 7-day `jwt` cookie), which only
///    ever exists to mint access tokens;
///  * an **access token**, 15 minutes, sent as `Authorization: Bearer` on every
///    API call.
///
/// [AuthController] owns caching, expiry and single-flight refresh for the
/// access token. It does **not** own the session — that differs completely
/// between a WebView (which holds a real cookie jar) and the pasted-cookie
/// fallback. Hence this interface.
library;

/// A freshly minted access token and how long the server says it lasts.
class AccessToken {
  const AccessToken(this.value, this.lifetime);

  final String value;
  final Duration lifetime;
}

abstract class TokenSource {
  /// Mints a fresh access token.
  ///
  /// Returns null when there is no session to mint from — the caller treats
  /// that as "browse anonymously", which is fine for public courses.
  ///
  /// Throws [ApiException] with 401 when a session existed but the server
  /// rejected it, which means the user must sign in again.
  Future<AccessToken?> mint();

  /// Whether this source can run an interactive sign-in (i.e. show a login UI
  /// that ends in a working session). False for the pasted-cookie fallback,
  /// where the user has to fetch the credential themselves.
  bool get supportsInteractiveLogin;

  /// Forgets the session. Must leave the source usable for a later sign-in.
  Future<void> clear();

  void dispose() {}
}

/// A [TokenSource] that can be handed a session cookie obtained outside the app.
///
/// Only the fallback path implements this. The WebView source deliberately does
/// not: it never reads the cookie, which is what makes `HttpOnly` irrelevant
/// to it.
abstract class CookieAcceptingTokenSource implements TokenSource {
  Future<void> acceptSessionCookie(String cookie);
}
