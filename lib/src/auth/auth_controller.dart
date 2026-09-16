/// Sign-in state for the app.
///
/// # How TUM-Live authentication works
///
/// TUM-Live uses SAML single sign-on — `GET /api/v2/login-options` reports
/// `useSaml: true`. There is no username/password endpoint to call, and there
/// should not be: the TUM password gates email, TUMonline and grades, so it
/// belongs only in TUM's own login page. The app shows that page in a WebView
/// rather than collecting credentials itself.
///
/// ```
///   WebView → https://tum.live/saml/out → TUM IdP → assertion back to gocast
///           → Set-Cookie: jwt=<RS256, 7 days>; Secure; HttpOnly
///   POST /api/v2/auth/token  (with that cookie)
///           → { "access_token": ..., "expires_in": 900 }
///   every API call → Authorization: Bearer <access_token>
/// ```
///
/// This class owns the **access token**: caching it, refreshing before it
/// expires, and making sure ten simultaneous API calls cause one refresh rather
/// than ten. It does not own the session — see [TokenSource].
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../api/api_exception.dart';
import '../api/models.dart';
import '../api/tum_live_api.dart';
import 'token_source.dart';

enum AuthStatus {
  /// Still checking for an existing session — show a splash, not a login screen.
  restoring,

  /// Browsing works, but only public courses.
  signedOut,

  signedIn,
}

class AuthController extends ChangeNotifier {
  AuthController({
    required TokenSource source,
    http.Client? client,
    this.origin = TumLiveApi.defaultOrigin,
  }) : _source = source,
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  /// Scheme + host of the TUM-Live deployment, e.g. `https://tum.live`.
  final String origin;

  final TokenSource _source;
  final http.Client _client;
  final bool _ownsClient;

  /// Re-mint this long before expiry, so a call never leaves with a token that
  /// dies in flight.
  static const Duration _refreshMargin = Duration(minutes: 2);

  /// How long an API call will wait for a token before going out anonymously.
  static const Duration _mintTimeout = Duration(seconds: 3);

  AuthStatus _status = AuthStatus.restoring;
  AuthStatus get status => _status;

  bool get isSignedIn => _status == AuthStatus.signedIn;

  TumUser? _user;
  TumUser? get user => _user;

  /// Whether the app can run sign-in itself, or has to send the user elsewhere
  /// for a session cookie. Drives which login screen is shown.
  bool get supportsInteractiveLogin => _source.supportsInteractiveLogin;

  String? _accessToken;
  DateTime? _accessTokenExpiry;

  /// Guards against several API calls all minting a token at once.
  Future<String?>? _pendingMint;

  /// Where the SSO flow starts.
  Uri get ssoUrl => Uri.parse('$origin/saml/out');

  /// Looks for an existing session and verifies it still works.
  ///
  /// Call once at startup. On the WebView source this also covers the common
  /// case where gocast's 7-day cookie lapsed but the identity provider still
  /// remembers the user — that renews silently, and they stay signed in.
  Future<void> restore() => refreshSession();

  /// Re-checks whether there is a working session, and loads the user if so.
  ///
  /// Also called after an interactive login finishes, which is how the login
  /// screen reports success without knowing anything about tokens.
  Future<void> refreshSession() async {
    _accessToken = null;
    _accessTokenExpiry = null;
    try {
      final String? token = await _acquireToken();
      if (token == null) {
        _setStatus(AuthStatus.signedOut);
        return;
      }
      _user = await _fetchUser();
      _setStatus(AuthStatus.signedIn);
    } on Object {
      // Expired, revoked, or offline. Start clean rather than half signed in.
      _user = null;
      _accessToken = null;
      _accessTokenExpiry = null;
      _setStatus(AuthStatus.signedOut);
    }
  }

  /// Signs in with a session cookie obtained outside the app.
  ///
  /// Only works on the fallback source; the WebView source never handles a raw
  /// cookie. Throws [UnsupportedError] elsewhere.
  Future<void> signInWithSessionCookie(String cookie) async {
    final TokenSource source = _source;
    if (source is! CookieAcceptingTokenSource) {
      throw UnsupportedError(
        'This build signs in through a WebView, not a pasted cookie.',
      );
    }
    await source.acceptSessionCookie(cookie);
    _accessToken = null;
    _accessTokenExpiry = null;

    // Verify before claiming success, so a bad paste cannot leave the app stuck.
    //
    // Minting has to be checked explicitly: bearerToken() deliberately falls
    // back to an anonymous request, so a successful /users/me proves nothing
    // about the cookie on its own.
    try {
      final String? token = await _acquireToken();
      if (token == null) {
        throw ApiException(401, 'That session cookie was rejected.');
      }
      _user = await _fetchUser();
    } on Object {
      await source.clear();
      rethrow;
    }
    _setStatus(AuthStatus.signedIn);
  }

  Future<void> signOut() async {
    _accessToken = null;
    _accessTokenExpiry = null;
    _user = null;
    await _source.clear();
    _setStatus(AuthStatus.signedOut);
  }

  /// The bearer token for the next API call, minting a fresh one if needed.
  ///
  /// Returns null when signed out — callers treat that as "make the request
  /// anonymously", which is exactly right for public courses.
  Future<String?> bearerToken() {
    final String? cached = _cachedToken();
    if (cached != null) return Future<String?>.value(cached);

    // Bounded on purpose. TumLiveApi awaits this before *every* request, so a
    // slow session probe — booting a WebView, or a silent SSO round trip — would
    // otherwise hold up calls that work perfectly well without a token. Public
    // courses need no authentication, so after [_mintTimeout] we go out
    // anonymously and let the mint finish in the background; when it lands,
    // listeners reload with authenticated data.
    return _sharedMint().timeout(_mintTimeout, onTimeout: () => null);
  }

  /// Same, but willing to wait. Used by the session probe, which is allowed to
  /// be slow because nothing is blocked on it.
  Future<String?> _acquireToken() {
    final String? cached = _cachedToken();
    if (cached != null) return Future<String?>.value(cached);
    return _sharedMint();
  }

  String? _cachedToken() {
    final DateTime? expiry = _accessTokenExpiry;
    final bool usable =
        _accessToken != null &&
        expiry != null &&
        DateTime.now().isBefore(expiry.subtract(_refreshMargin));
    return usable ? _accessToken : null;
  }

  /// Collapses concurrent refreshes into one request.
  ///
  /// Never throws: a failed mint means "no token", and the caller's job is then
  /// to make the request anonymously. Letting a dead session throw out of here
  /// would break browsing public courses, which needs no session at all. The
  /// cases that matter are still handled — [_mint] signs out on a 401.
  Future<String?> _sharedMint() {
    return _pendingMint ??= _mint()
        .catchError((Object _) => null)
        .whenComplete(() {
          _pendingMint = null;
        });
  }

  Future<String?> _mint() async {
    final AccessToken? minted;
    try {
      minted = await _source.mint();
    } on ApiException catch (e) {
      // A 401 here means the session is gone for good, not that this one call
      // failed. Staying "signed in" would retry a credential that can never
      // work again, on every request.
      if (e.isUnauthorized) _forgetSession();
      rethrow;
    }
    if (minted == null) {
      _accessToken = null;
      _accessTokenExpiry = null;
      return null;
    }
    _accessToken = minted.value;
    _accessTokenExpiry = DateTime.now().add(minted.lifetime);
    return minted.value;
  }

  /// Drops local sign-in state. The source has already discarded the session by
  /// the time this runs, so it deliberately does not call `clear()` again.
  void _forgetSession() {
    _accessToken = null;
    _accessTokenExpiry = null;
    _user = null;
    _setStatus(AuthStatus.signedOut);
  }

  /// Fetches the current user with a freshly minted token. Doubles as the
  /// "is this session actually valid?" check.
  Future<TumUser> _fetchUser() async {
    final TumLiveApi api = TumLiveApi(
      client: _client,
      baseUrl: '$origin/api/v2',
      tokenProvider: bearerToken,
    );
    return api.getCurrentUser();
  }

  void _setStatus(AuthStatus status) {
    _status = status;
    notifyListeners();
  }

  @override
  void dispose() {
    _source.dispose();
    if (_ownsClient) _client.close();
    super.dispose();
  }
}
