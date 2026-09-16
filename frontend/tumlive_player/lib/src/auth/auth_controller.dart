/// Sign-in state for the app.
///
/// # How TUM-Live authentication works
///
/// TUM-Live uses SAML single sign-on (`GET /api/v2/login-options` reports
/// `useSaml: true`). There is no username/password endpoint we can call — the
/// user authenticates against the TUM identity provider in a browser, and gocast
/// turns the result into a session:
///
/// ```
///   browser → https://tum.live/saml/out → TUM IdP → assertion back to gocast
///           → Set-Cookie: jwt=<RS256, 7 days>; Secure; HttpOnly
///   POST /api/v2/auth/token  (with that cookie)
///           → { "access_token": ..., "expires_in": 900 }
///   every API call → Authorization: Bearer <access_token>
/// ```
///
/// So there are **two** credentials, and it matters which is which:
///
/// * the **session cookie**, long-lived (7 days), persisted, sent only to mint
///   access tokens;
/// * the **access token**, 15 minutes, kept in memory only, sent on every call.
///
/// This class owns that exchange. How the cookie is *obtained* is deliberately
/// not its business — see [signInWithSessionCookie].
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../api/api_exception.dart';
import '../api/models.dart';
import '../api/tum_live_api.dart';
import 'credential_store.dart';

enum AuthStatus {
  /// Still reading persisted credentials — show a splash, not a login screen.
  restoring,

  /// Browsing works, but only public courses.
  signedOut,

  signedIn,
}

class AuthController extends ChangeNotifier {
  AuthController({
    required CredentialStore store,
    http.Client? client,
    this.origin = TumLiveApi.defaultOrigin,
  }) : _store = store,
       _client = client ?? http.Client();

  /// Scheme + host of the TUM-Live deployment, e.g. `https://tum.live`.
  final String origin;

  final CredentialStore _store;
  final http.Client _client;

  /// Re-mint this long before expiry, so a call never leaves with a token that
  /// dies in flight.
  static const Duration _refreshMargin = Duration(minutes: 2);

  AuthStatus _status = AuthStatus.restoring;
  AuthStatus get status => _status;

  bool get isSignedIn => _status == AuthStatus.signedIn;

  TumUser? _user;
  TumUser? get user => _user;

  String? _sessionCookie;

  String? _accessToken;
  DateTime? _accessTokenExpiry;

  /// Guards against several API calls all minting a token at once.
  Future<String?>? _pendingMint;

  /// Where the SSO flow starts. Open this in a browser or WebView.
  Uri get ssoUrl => Uri.parse('$origin/saml/out');

  /// Reads any stored session and verifies it still works.
  ///
  /// Call once at startup. A stored cookie that the server has since rejected
  /// is discarded rather than kept around to fail later.
  Future<void> restore() async {
    _sessionCookie = await _store.readSessionCookie();
    if (_sessionCookie == null) {
      _setStatus(AuthStatus.signedOut);
      return;
    }
    try {
      _user = await _fetchUser();
      _setStatus(AuthStatus.signedIn);
    } on Object {
      // Expired or revoked. Start clean rather than half signed in.
      await signOut();
    }
  }

  /// Signs in with a gocast session cookie obtained outside the app.
  ///
  /// **This is the one deliberately temporary piece of the prototype.** Today
  /// the user completes SSO in a real browser and pastes the `jwt` cookie in.
  /// It is ugly, but it is honest: it works on every platform including macOS,
  /// where `webview_flutter` has no implementation.
  ///
  /// To replace it with a real flow, drive [ssoUrl] in a WebView, read the `jwt`
  /// cookie from the platform cookie store when the flow lands back on
  /// [origin], and call this method with it. Nothing else changes.
  ///
  /// Throws [ApiException] if the cookie does not produce a working session.
  Future<void> signInWithSessionCookie(String cookie) async {
    final String trimmed = _normaliseCookie(cookie);
    if (trimmed.isEmpty) {
      throw ApiException(400, 'That does not look like a session cookie.');
    }

    // Verify before storing, so a bad paste cannot leave the app stuck.
    _sessionCookie = trimmed;
    _accessToken = null;
    _accessTokenExpiry = null;
    try {
      _user = await _fetchUser();
    } on Object {
      _sessionCookie = null;
      rethrow;
    }

    await _store.writeSessionCookie(trimmed);
    _setStatus(AuthStatus.signedIn);
  }

  Future<void> signOut() async {
    _sessionCookie = null;
    _accessToken = null;
    _accessTokenExpiry = null;
    _user = null;
    await _store.clear();
    _setStatus(AuthStatus.signedOut);
  }

  /// The bearer token for the next API call, minting a fresh one if needed.
  ///
  /// Returns null when signed out — callers treat that as "make the request
  /// anonymously", which is exactly right for public courses.
  ///
  /// This is what gets handed to `TumLiveApi.tokenProvider`.
  Future<String?> bearerToken() async {
    if (_sessionCookie == null) return null;

    final DateTime? expiry = _accessTokenExpiry;
    final bool usable =
        _accessToken != null &&
        expiry != null &&
        DateTime.now().isBefore(expiry.subtract(_refreshMargin));
    if (usable) return _accessToken;

    // Collapse concurrent refreshes into one request.
    return _pendingMint ??= _mintAccessToken().whenComplete(() {
      _pendingMint = null;
    });
  }

  /// Exchanges the session cookie for a short-lived bearer token.
  Future<String?> _mintAccessToken() async {
    final String? cookie = _sessionCookie;
    if (cookie == null) return null;

    final Uri uri = Uri.parse('$origin/api/v2/auth/token');
    final http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: <String, String>{
              'Cookie': 'jwt=$cookie',
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      throw NetworkException(e, uri: uri);
    }

    if (response.statusCode == 401) {
      // The session is gone for good; a retry would fail the same way.
      await signOut();
      throw ApiException(401, 'Your TUM-Live session has expired.', uri: uri);
    }
    if (response.statusCode != 200) {
      throw ApiException(response.statusCode, 'Could not refresh the session.',
          uri: uri);
    }

    final Object? decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw ApiException(200, 'Unexpected token response.', uri: uri);
    }
    final Object? token = decoded['access_token'];
    if (token is! String || token.isEmpty) {
      throw ApiException(200, 'Token response had no access_token.', uri: uri);
    }
    final int expiresIn = decoded['expires_in'] is int
        ? decoded['expires_in'] as int
        : 900;

    _accessToken = token;
    _accessTokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));
    return token;
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

  /// Accepts what people actually paste: a bare value, `jwt=<value>`, or a
  /// whole `Cookie:` header copied out of the browser's network tab.
  String _normaliseCookie(String raw) {
    String value = raw.trim();
    if (value.isEmpty) return '';
    if (value.toLowerCase().startsWith('cookie:')) {
      value = value.substring('cookie:'.length).trim();
    }
    for (final String part in value.split(';')) {
      final String candidate = part.trim();
      if (candidate.startsWith('jwt=')) {
        return candidate.substring(4).trim();
      }
    }
    // No `jwt=` anywhere: assume the whole thing is the value.
    return value;
  }

  void _setStatus(AuthStatus status) {
    if (_status == status) {
      notifyListeners();
      return;
    }
    _status = status;
    notifyListeners();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }
}
