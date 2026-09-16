# TUMLive Player

A third-party client for [TUM-Live](https://tum.live), TUM's lecture recording
service. Browse courses, watch recordings, resume where you left off.

It talks **directly to TUM-Live's public API v2** — there is no backend of our
own. See `../../backend/DESIGN.md` for why, and for what a backend would add
later (cut detection for skipping dead time is the first real candidate).

## Running it

```bash
flutter pub get
flutter run -d macos      # or -d chrome, -d ios, -d android
```

Public courses work immediately, signed out. Signing in adds your enrolled
courses and syncs watch progress.

There is also a command-line smoke test that hits the real API:

```bash
dart run tool/api_smoke.dart
```

Use it when a response looks wrong — it is much faster than launching the app,
and it works because `lib/src/api/` imports nothing from Flutter.

## Layout

```
lib/
  main.dart                     entry point, theme, AppScope wiring
  src/
    app_scope.dart              dependency injection via InheritedNotifier
    api/
      models.dart               Course, Lecture, Semester, … (pure Dart)
      tum_live_api.dart         every HTTP call lives here
      api_exception.dart        ApiException / NetworkException
    auth/
      auth_controller.dart      session cookie -> bearer token lifecycle
      credential_store.dart     persistence, behind an interface
      login_page.dart           sign-in UI
    home/home_page.dart         semester picker, course lists
    course/course_page.dart     one course's lectures
    player/
      player_page.dart          resolves (slug, id) -> a playable URL
      lecture_player.dart       owns the VideoPlayerController
      player_controls.dart      the auto-hiding control bar
    common/
      async_builder.dart        one loading/error/retry pattern for all screens
      formatting.dart           durations, dates, semester labels
```

### Two rules that keep this tidy

1. **`api/` never imports Flutter.** That is what makes `tool/api_smoke.dart`
   and the unit tests possible without a simulator. Do not put a `BuildContext`
   in there.
2. **Widgets never build URLs.** Anything that touches TUM-Live goes through
   `TumLiveApi`. If a screen needs data, add a method there first.

### Why the layers split where they do

`player/` is three files rather than one because they fail differently:

- `player_controls.dart` — pure UI over an initialised controller. No network,
  no async beyond timers.
- `lecture_player.dart` — owns the `VideoPlayerController`: loading, failure,
  retry. Takes a plain URL, so the widget tests drive it with a fake platform
  and no HTTP at all.
- `player_page.dart` — the only part that knows TUM-Live exists. Resolves a
  lecture id into a signed URL, restores your position, reports progress.

That last split is not cosmetic. **Playlist URLs are signed and expire in about
seven hours**, so the app stores lecture ids and re-resolves before playback.
An earlier version hardcoded a URL and broke every single day.

## Tests

```bash
flutter test
```

- `widget_test.dart` — the player: control bar, seek handle, failure states.
  Drives a fake `VideoPlayerPlatform`; never touches the network.
- `api_test.dart` — JSON parsing and request shaping, against `MockClient`.
- `auth_test.dart` — the token lifecycle: cache, single-flight refresh, expiry.
- `app_flow_test.dart` — home → course → lecture list against a fake server.

## Known placeholders

Two things are deliberately unfinished, and both are marked in the code:

- **Sign-in asks you to paste a cookie.** TUM-Live uses SAML SSO, so the user
  authenticates in a real browser. On phones this becomes a WebView; on macOS
  `webview_flutter` has no implementation, hence the paste. Replacing it means
  calling `AuthController.signInWithSessionCookie` from a WebView flow —
  nothing else changes.
- **The session cookie is stored in `SharedPreferences`**, which is plain text.
  Swap `SharedPreferencesCredentialStore` for a `flutter_secure_storage`
  implementation of the same interface before shipping anything.

## Not built yet

Chapter markers (`/sections` is already wired in the API client, nothing renders
them), bookmarks, subtitles, search, offline download, and the black-screen /
silence skipping described in `backend/DESIGN.md`.
