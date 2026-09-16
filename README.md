# TUMLive Player

A third-party client for [TUM-Live](https://tum.live), TUM's lecture recording
service. Browse courses, watch recordings, resume where you left off.

Flutter, targeting macOS / iOS / Android (Windows and Linux build, with a
caveat on login — see below). It talks **directly to TUM-Live's public API v2**;
there is no backend of our own.

## Quick start

```bash
flutter pub get
flutter run -d macos          # or -d ios, -d android, -d chrome
flutter test                  # 68 tests, no network
dart run tool/api_smoke.dart  # hits the real API, prints what comes back
```

Public courses work immediately, signed out.

---

## The three facts that explain every design decision

**1. gocast already ships the backend.** TUM-Live's server is
[TUM-Dev/gocast](https://github.com/TUM-Dev/gocast), and it exposes a documented
REST API at `https://tum.live/api/v2` (Swagger at `/api/v2/docs`), generated from
`apiv2/server/apiv2.proto`. Browsing, playback, watch progress and bookmarks are
all endpoints that already exist. Public courses need no authentication at all.

**2. Playlist URLs expire in about 7 hours.** gocast signs every playlist URL
with an RS256 JWT (`tools/stream-signing.go`) and the edge server validates it —
including re-signing every `.ts` segment. So **never store a playlist URL**.
Store `(courseSlug, lectureId)` and re-resolve immediately before playback. This
is why `player_page.dart` exists as a layer of its own.

**3. Authentication is SAML SSO, with two credentials.** `GET /api/v2/login-options`
reports `useSaml: true`. There is no username/password endpoint to call, and
there should not be — the TUM password also gates email, TUMonline and grades.

```
session cookie (jwt)   hard 7 days, no sliding window   → only mints tokens
access token           15 minutes                       → sent on every API call
```

The session is renewed by bouncing through `/saml/out`. If the TUM identity
provider still remembers the user — its own session is much longer — that
completes silently with no password prompt. That is why a browser stays logged
in to tum.live for months even though gocast's cookie is only 7 days.

---

## Layout

```
lib/
  main.dart                     entry point, theme, platform token-source choice
  src/
    app_scope.dart              DI via InheritedNotifier
    api/
      models.dart               Course, Lecture, Semester, … (pure Dart)
      tum_live_api.dart         every HTTP call lives here
      api_exception.dart        ApiException / NetworkException
    auth/
      auth_controller.dart      access-token cache, refresh margin, single-flight
      token_source.dart         the session/token seam
      webview_token_source.dart WebView cookie jar as the session store
      cookie_token_source.dart  pasted-cookie fallback (Linux, web)
      credential_store.dart     persistence, fallback only
      login_page.dart           picks the right sign-in screen
      webview_login_page.dart   TUM's real login page, in-app
      cookie_login_page.dart    the fallback paste form
    home/home_page.dart         semester picker, course lists
    course/course_page.dart     one course's lectures, with progress bars
    player/
      player_page.dart          resolves (slug, id) → a signed URL; progress sync
      lecture_player.dart       owns the VideoPlayerController
      player_controls.dart      auto-hiding control bar, seek handle
    common/
      async_builder.dart        one loading/error/retry pattern for all screens
      formatting.dart           durations, dates, semester labels
test/                           see Tests below
tool/api_smoke.dart             CLI against the live API
DESIGN.md                       gocast internals + the cut-detection plan
LEARNING.md                     reading order and exercises
```

### Two rules that keep this tidy

1. **`api/` never imports Flutter.** That is what lets `tool/api_smoke.dart` and
   the unit tests run without a simulator. No `BuildContext` in there.
2. **Widgets never build URLs.** Everything touching TUM-Live goes through
   `TumLiveApi`. If a screen needs data, add a method there first.

### Why the player is three files

They fail differently, and splitting them is what keeps the tests cheap:

- `player_controls.dart` — pure UI over an initialised controller.
- `lecture_player.dart` — owns the `VideoPlayerController`: load, fail, retry.
  Takes a plain URL, so widget tests drive it with a fake platform and no HTTP.
- `player_page.dart` — the only part that knows TUM-Live exists.

---

## How sign-in works

`AuthController` owns the **access token** — caching, refresh margin, and
collapsing concurrent refreshes into one request. It does *not* own the session,
because that differs per platform. That is what `TokenSource` is for.

**`WebViewTokenSource`** (Android, iOS, macOS, Windows) keeps a hidden WebView on
the tum.live origin and asks *it* to call the token endpoint:

```js
await fetch('/api/v2/auth/token', {method: 'POST', credentials: 'include'})
```

The WebView attaches the cookie itself, so the app never reads it. gocast's
cookie is `HttpOnly` — that stops mattering entirely. Nothing long-lived is
written to our own storage. The jar lives in the app's sandbox container
(`Library/Cookies/` on macOS), protected by the sandbox and file
permissions — not the Keychain.

It also gives **silent renewal**: `mint()` retries once through `/saml/out`
before giving up. Worth noting a server-side auth broker *could not* do this —
renewal needs the IdP session, and that lives in a cookie jar on the device.

Sign-in shows TUM's real login page in a WebView. The user types their TUM ID
and password there; the app never sees them.

**`CookieTokenSource`** (Linux, web) is the fallback where no WebView exists:
the user copies the `jwt` cookie from a browser. This path *does* store the
cookie via `SharedPreferences`, which is plain text — swap
`SharedPreferencesCredentialStore` for a `flutter_secure_storage` implementation
of the same interface before shipping on those platforms.

---

## API endpoints in use

Relative to `https://tum.live/api/v2`. Full list at `/api/v2/docs`.

| Purpose | Endpoint |
|---|---|
| Semester list + current | `GET /semesters` |
| Public course listing | `GET /courses?year=&term=` |
| Course + all its lectures | `GET /courses/{slug}?year=&term=` |
| Enrolled / pinned / live | `GET /courses/enrolled`, `/courses/pinned`, `/courses/live` |
| One lecture (signed URLs) | `GET /streams/{slug}/{id}` |
| Chapter markers | `GET /streams/{slug}/{id}/sections` |
| Watch progress | `GET /progress?stream_ids=…`, `PATCH /progress/{id}` |
| Current user | `GET /users/me` |
| Mint access token | `POST /auth/token` (session cookie) |

Response JSON is lowerCamelCase (`playlistUrl`, `lastRecording`). Two shapes
that catch people out: lectures arrive under `streams`, and `/courses/live`
returns `liveCourses` (course+lecture pairs), not `courses`.

---

## Tests

```bash
flutter test          # 68 tests
```

- `widget_test.dart` — the player: control bar, seek handle, failure states.
  Drives a fake `VideoPlayerPlatform`; never touches the network.
- `api_test.dart` — JSON parsing and request shaping, against `MockClient`.
- `auth_test.dart` — token lifecycle: cache, single-flight refresh, expiry,
  and that `AuthController` behaves identically for any `TokenSource`.
- `app_flow_test.dart` — home → course → player → back, against a fake server.

**Every bug found in this code so far has lived in the seam between two
screens** — one fired when `PlayerPage` mounted, another when it unmounted.
Unit tests could not see either. When you add a screen, test the whole round
trip, in *and* back out.

---

## Current state

**Works:** browsing by semester, course lists, lecture lists with watch-progress
bars, playback with resume, progress sync, camera-angle switching, playback
speed, sign-in on WebView platforms.

**Not verified:** the SSO round trip itself has never been run against a real TUM
login — it needs credentials and a human at the keyboard. Everything around it is
tested and it builds and starts cleanly, but expect to iterate. The likely rough
edges are landing-URL detection in `webview_login_page.dart` and whether
`callAsyncJavaScript` behaves the same across platforms.

**Not built:** chapter-marker UI (`api.getSections()` exists, nothing renders it),
pin/unpin UI (`api.setCoursePinned()` exists, nothing calls it), bookmarks,
subtitles, search, offline download, and black-screen/silence skipping.

### Good next steps

1. **Pin/unpin** — the API call is written and tested; you add a button. Small,
   but it touches every layer: UI → API → auth → state refresh.
2. **Chapter markers** — `getSections()` returns `VideoSection` with a
   `startOffset`; draw ticks on the seek bar. Needs no login.
3. **Cut detection** — the big one, and the only feature that genuinely needs a
   backend of our own. See `DESIGN.md`.

---

## Gotchas

- **Never cache a playlist URL.** See fact 2 above.
- **`setState` with an arrow body and a `Future` field throws.**
  `setState(() => _future = _load())` returns the assignment's value. Use a block.
- **Reading an `InheritedWidget` in `initState` throws.** First load belongs in
  `didChangeDependencies`.
- **After moving the project, run `flutter clean`.** Xcode caches the old
  absolute path and will write builds to the previous location.
- **`video_player` has no HLS on Windows or Linux.** If desktop matters beyond
  macOS, switch to `media_kit`.

## Be a good citizen

This is a university service with real costs. Cache, back off on errors, send a
descriptive `User-Agent` (`tum_live_api.dart` does), don't scrape whole semesters
in a loop, and honour course visibility.
