/// Where the TUM-Live session credential lives between app launches.
library;

import 'package:shared_preferences/shared_preferences.dart';

/// Persistence for the long-lived session cookie.
///
/// Behind an interface on purpose: the prototype uses [SharedPreferences], but
/// a shipped app must not. See [SharedPreferencesCredentialStore].
abstract class CredentialStore {
  Future<String?> readSessionCookie();

  Future<void> writeSessionCookie(String cookie);

  Future<void> clear();
}

/// Prototype implementation.
///
/// ⚠️ **Not suitable for release.** `SharedPreferences` is plain text on disk
/// (`NSUserDefaults` / a shared-prefs XML file); anything with filesystem access
/// can read the session cookie, and that cookie is good for seven days.
///
/// The fix is one class: add `flutter_secure_storage`, implement
/// [CredentialStore] against it, and pass it to `AuthController`. Nothing else
/// in the app needs to change — which is the whole reason this is an interface.
class SharedPreferencesCredentialStore implements CredentialStore {
  static const String _key = 'tumlive.session_cookie';

  @override
  Future<String?> readSessionCookie() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? value = prefs.getString(_key);
    return (value == null || value.isEmpty) ? null : value;
  }

  @override
  Future<void> writeSessionCookie(String cookie) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, cookie);
  }

  @override
  Future<void> clear() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}

/// In-memory store, for tests.
class MemoryCredentialStore implements CredentialStore {
  String? _cookie;

  @override
  Future<String?> readSessionCookie() async => _cookie;

  @override
  Future<void> writeSessionCookie(String cookie) async => _cookie = cookie;

  @override
  Future<void> clear() async => _cookie = null;
}
