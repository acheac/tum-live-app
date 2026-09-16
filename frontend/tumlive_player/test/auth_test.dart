// Tests for the session-cookie -> bearer-token exchange.
//
// The thing worth protecting here is the token lifecycle: mint lazily, cache
// until nearly expired, never mint twice at once, and give up cleanly when the
// session is gone. Getting that wrong shows up as either a storm of requests or
// a user who appears signed in but cannot load anything.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tumlive_player/src/api/api_exception.dart';
import 'package:tumlive_player/src/auth/auth_controller.dart';
import 'package:tumlive_player/src/auth/credential_store.dart';

/// Records what the controller asked for, and answers plausibly.
class FakeServer {
  FakeServer({this.tokenStatus = 200, this.userStatus = 200});

  int tokenStatus;
  int userStatus;

  /// Lifetime the fake hands out, in seconds. Setting this below the
  /// controller's two-minute refresh margin makes every token look stale the
  /// instant it arrives, which is how these tests reach the re-mint path
  /// without waiting fifteen real minutes.
  int expiresIn = 900;

  int tokenCalls = 0;
  int userCalls = 0;
  final List<String?> cookiesSeen = <String?>[];
  final List<String?> bearersSeen = <String?>[];

  late final http.Client client = MockClient((http.Request request) async {
    if (request.url.path.endsWith('/auth/token')) {
      tokenCalls++;
      cookiesSeen.add(request.headers['Cookie']);
      if (tokenStatus != 200) {
        return http.Response('{"message":"no session"}', tokenStatus);
      }
      return http.Response(
        jsonEncode(<String, dynamic>{
          'access_token': 'access-$tokenCalls',
          'token_type': 'Bearer',
          'expires_in': expiresIn,
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }
    if (request.url.path.endsWith('/users/me')) {
      userCalls++;
      bearersSeen.add(request.headers['Authorization']);
      if (userStatus != 200) {
        return http.Response('{"message":"unauthenticated"}', userStatus);
      }
      return http.Response(
        jsonEncode(<String, dynamic>{
          'user': <String, dynamic>{
            'id': 12345,
            'name': 'Ada',
            'lastName': 'Lovelace',
            'email': 'ada@tum.de',
          },
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }
    return http.Response('{}', 404);
  });
}

void main() {
  late FakeServer server;
  late MemoryCredentialStore store;
  late AuthController auth;

  AuthController build() => AuthController(store: store, client: server.client);

  setUp(() {
    server = FakeServer();
    store = MemoryCredentialStore();
    auth = build();
  });

  group('restore', () {
    test('with nothing stored, the app starts signed out but usable', () async {
      await auth.restore();

      expect(auth.status, AuthStatus.signedOut);
      expect(auth.isSignedIn, isFalse);
      // Signed out still browses public courses, so no token is expected.
      expect(await auth.bearerToken(), isNull);
      expect(server.tokenCalls, 0);
    });

    test('a stored cookie that still works signs the user back in', () async {
      await store.writeSessionCookie('cookie-value');

      await auth.restore();

      expect(auth.status, AuthStatus.signedIn);
      expect(auth.user?.displayName, 'Ada Lovelace');
    });

    test('a stored cookie the server rejects is discarded', () async {
      await store.writeSessionCookie('stale');
      server.tokenStatus = 401;

      await auth.restore();

      expect(auth.status, AuthStatus.signedOut);
      // Critically, it is gone from disk — otherwise every launch retries it.
      expect(await store.readSessionCookie(), isNull);
    });
  });

  group('sign in', () {
    test('stores the cookie and loads the user', () async {
      await auth.signInWithSessionCookie('cookie-value');

      expect(auth.isSignedIn, isTrue);
      expect(await store.readSessionCookie(), 'cookie-value');
      expect(server.cookiesSeen.single, 'jwt=cookie-value');
    });

    test('a rejected cookie is not persisted', () async {
      server.tokenStatus = 401;

      await expectLater(
        auth.signInWithSessionCookie('bad'),
        throwsA(isA<ApiException>()),
      );

      expect(auth.isSignedIn, isFalse);
      expect(await store.readSessionCookie(), isNull);
    });

    test('an empty paste is rejected before any request', () async {
      await expectLater(
        auth.signInWithSessionCookie('   '),
        throwsA(isA<ApiException>()),
      );
      expect(server.tokenCalls, 0);
    });

    group('accepts what people actually paste', () {
      test('a bare value', () async {
        await auth.signInWithSessionCookie('abc123');
        expect(server.cookiesSeen.single, 'jwt=abc123');
      });

      test('a name=value pair', () async {
        await auth.signInWithSessionCookie('jwt=abc123');
        expect(server.cookiesSeen.single, 'jwt=abc123');
      });

      test('a whole Cookie header with other cookies in it', () async {
        await auth.signInWithSessionCookie(
          'Cookie: _ga=GA1.2.3; jwt=abc123; other=zzz',
        );
        expect(server.cookiesSeen.single, 'jwt=abc123');
      });
    });
  });

  group('token lifecycle', () {
    test('the token is minted once and then reused', () async {
      await auth.signInWithSessionCookie('cookie-value');
      final int afterSignIn = server.tokenCalls;

      final String? first = await auth.bearerToken();
      final String? second = await auth.bearerToken();

      expect(first, isNotNull);
      expect(second, first);
      expect(server.tokenCalls, afterSignIn, reason: 'cached, not re-minted');
    });

    test('a token past its refresh margin is re-minted', () async {
      server.expiresIn = 1;
      await auth.signInWithSessionCookie('cookie-value');
      final int baseline = server.tokenCalls;

      await auth.bearerToken();

      expect(server.tokenCalls, baseline + 1);
    });

    test('concurrent callers share a single mint', () async {
      // Every token arrives already stale, so all three callers want a new one.
      server.expiresIn = 1;
      await auth.signInWithSessionCookie('cookie-value');
      final int baseline = server.tokenCalls;

      final List<String?> tokens = await Future.wait<String?>(<Future<String?>>[
        auth.bearerToken(),
        auth.bearerToken(),
        auth.bearerToken(),
      ]);

      expect(
        server.tokenCalls,
        baseline + 1,
        reason: 'three simultaneous callers must not mint three tokens',
      );
      expect(tokens.toSet(), hasLength(1));
    });

    test('the minted token is what reaches the API', () async {
      await auth.signInWithSessionCookie('cookie-value');
      expect(server.bearersSeen.last, startsWith('Bearer access-'));
    });

    test('a session that dies mid-run signs the user out', () async {
      server.expiresIn = 1;
      await auth.signInWithSessionCookie('cookie-value');
      expect(auth.isSignedIn, isTrue);

      // The seven-day session cookie expires while the app is open.
      server.tokenStatus = 401;

      await expectLater(auth.bearerToken(), throwsA(isA<ApiException>()));

      // Not just a failed call: the dead session must be cleared, or every
      // later request retries a credential that can never work again.
      expect(auth.isSignedIn, isFalse);
      expect(await store.readSessionCookie(), isNull);
    });
  });

  group('sign out', () {
    test('clears the stored cookie and the in-memory user', () async {
      await auth.signInWithSessionCookie('cookie-value');

      await auth.signOut();

      expect(auth.status, AuthStatus.signedOut);
      expect(auth.user, isNull);
      expect(await store.readSessionCookie(), isNull);
      expect(await auth.bearerToken(), isNull);
    });
  });

  test('the SSO url points at the SAML entry point', () {
    expect(auth.ssoUrl.toString(), 'https://tum.live/saml/out');
  });
}
