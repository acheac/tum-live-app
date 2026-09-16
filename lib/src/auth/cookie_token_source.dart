/// Fallback session source: a gocast session cookie the user obtained elsewhere.
///
/// Used where no WebView exists (Linux, and web where a headless WebView is not
/// practical), and as an escape hatch if the WebView flow fails.
///
/// The user completes SSO in a real browser and copies the `jwt` cookie in.
/// Clumsy, but it works on every platform and needs no plugins.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../api/api_exception.dart';
import 'credential_store.dart';
import 'token_source.dart';

class CookieTokenSource implements CookieAcceptingTokenSource {
  CookieTokenSource({
    required CredentialStore store,
    http.Client? client,
    this.origin = 'https://tum.live',
  }) : _store = store,
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  final String origin;
  final CredentialStore _store;
  final http.Client _client;
  final bool _ownsClient;

  String? _cookie;
  bool _loaded = false;

  /// The user has to leave the app to get the cookie, so there is no
  /// self-contained login we can run.
  @override
  bool get supportsInteractiveLogin => false;

  @override
  Future<AccessToken?> mint() async {
    final String? cookie = await _sessionCookie();
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
      // Gone for good; a retry would fail identically.
      await clear();
      throw ApiException(401, 'Your TUM-Live session has expired.', uri: uri);
    }
    if (response.statusCode != 200) {
      throw ApiException(
        response.statusCode,
        'Could not refresh the session.',
        uri: uri,
      );
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

    return AccessToken(token, Duration(seconds: expiresIn));
  }

  @override
  Future<void> acceptSessionCookie(String cookie) async {
    final String normalised = normaliseCookie(cookie);
    if (normalised.isEmpty) {
      throw ApiException(400, 'That does not look like a session cookie.');
    }
    _cookie = normalised;
    _loaded = true;
    await _store.writeSessionCookie(normalised);
  }

  @override
  Future<void> clear() async {
    _cookie = null;
    _loaded = true;
    await _store.clear();
  }

  @override
  void dispose() {
    if (_ownsClient) _client.close();
  }

  Future<String?> _sessionCookie() async {
    if (!_loaded) {
      _cookie = await _store.readSessionCookie();
      _loaded = true;
    }
    return _cookie;
  }

  /// Accepts what people actually paste: a bare value, `jwt=<value>`, or a whole
  /// `Cookie:` header copied out of a browser's network tab.
  static String normaliseCookie(String raw) {
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
}
