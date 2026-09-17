import 'package:flutter_test/flutter_test.dart';
import 'package:tumlive_player/src/auth/sso_cover.dart';

const String host = 'tum.live';

bool cover(String url, {bool noSessionYet = false, bool covered = true}) =>
    coverForUrl(
      url: Uri.parse(url),
      ownHost: host,
      noSessionYet: noSessionYet,
      covered: covered,
    );

void main() {
  group('coverForUrl', () {
    test('the first redirect is covered', () {
      // AuthController.ssoUrl, which is on our own origin — so the cover is up
      // from the very first frame rather than after a flash.
      expect(cover('https://tum.live/saml/out'), isTrue);
    });

    test('the SAML handshake is covered', () {
      // The bug this was written for: these are TUM-Live pages and they draw
      // its website, so exempting /saml/ let the site flash up mid-login.
      expect(cover('https://tum.live/saml/acs'), isTrue);
      expect(cover('https://tum.live/saml/metadata'), isTrue);
    });

    test('the landing page is covered', () {
      expect(cover('https://tum.live/'), isTrue);
      expect(cover('https://tum.live/course/2025/W/foo'), isTrue);
    });

    test('the identity provider is shown', () {
      // The one place the user has something to do.
      expect(
        cover('https://login.tum.de/idp/profile/SAML2/Redirect/SSO'),
        isFalse,
      );
      expect(cover('https://www.sso.tum.de/'), isFalse);
    });

    test('a look-alike host is not our origin', () {
      // Substring matching would have covered this one and hidden a page the
      // user needed.
      expect(cover('https://nottum.live/login'), isFalse);
      expect(cover('https://tum.live.evil.example/'), isFalse);
    });

    test('no session yet leaves the cover alone', () {
      // TUM's consent step: the page was uncovered on purpose so the user can
      // act, and an in-page navigation must not drop the cover back over it.
      expect(
        cover('https://tum.live/', noSessionYet: true, covered: false),
        isFalse,
      );
    });

    test('covering is never something to animate into', () {
      // Not a property of coverForUrl itself, but the reason the login page
      // fades the cover out over 220ms and in over 0: a fade-in would show the
      // page through a half-transparent cover for the length of the fade,
      // which is the flash again, slower. If this rule ever gains a "cover
      // gradually" state, that is the trap it walked into.
      expect(cover('https://tum.live/saml/acs'), isTrue);
      expect(cover('https://tum.live/'), isTrue);
    });

    test('but a covered page stays covered while waiting', () {
      expect(
        cover('https://tum.live/', noSessionYet: true, covered: true),
        isTrue,
      );
    });
  });
}
