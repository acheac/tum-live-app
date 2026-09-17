# TUMLive Player

[Download android apk here](https://github.com/user-attachments/files/32320502/app-release.apk.zip)

A third-party client for [TUM-Live](https://tum.live), TUM's lecture recording
service. Browse courses by semester, watch recordings, and pick up where you
left off.

It talks directly to TUM-Live's public API — there is no backend of our own, and
nothing about you is stored anywhere but on your device.

**What it does today:** browsing by semester, course and lecture lists with
watch-progress bars, playback with resume, progress sync back to TUM-Live,
camera-angle switching (combined / camera / slides), playback speed, and sign-in
for enrolled courses.

**What it doesn't do yet:** chapter markers, pinning courses, bookmarks,
subtitles, search, offline download, and skipping dead time.

Built with Flutter for macOS, iOS and Android. Windows and Linux build too, with
caveats — see [Platforms](#platforms).

## Requirements

- [Flutter](https://docs.flutter.dev/get-started/install) (stable channel)
- Xcode for macOS/iOS builds, Android Studio for Android builds

## Running it

```bash
flutter pub get
flutter run -d macos     # or: -d ios, -d android, -d chrome
```

Public courses work immediately, without signing in.

## Signing in

Sign in only if you want your enrolled courses, or lectures that aren't public.

Tap **Sign in** and TUM's own login page opens inside the app. Type your TUM ID
and password there — the app never sees them, and nothing but the session cookie
the login hands back is kept. That cookie lives in the app's own sandboxed
storage and is used only to ask TUM-Live for short-lived access tokens.

Sessions last seven days. After that the app quietly renews through TUM's single
sign-on, so in practice you rarely see the login page again.

On Linux and the web there is no in-app browser to do this, so those platforms
ask you to paste the `jwt` cookie from a browser instead.

## Using the player

- **Tap** anywhere to show or hide the controls; they fade on their own.
- **Drag the seek handle** to scrub. Your position is saved to TUM-Live, so the
  lecture resumes at the same spot in the app, on the website, or on another
  device.
- **Camera angle** — switch between the combined view, the lecture hall camera,
  and the slides, where the recording offers them.
- **Speed** — 0.5× up to 2×.

## Platforms

| Platform | Status |
|---|---|
| macOS, iOS, Android | Full support, in-app sign-in |
| Windows | Builds and signs in, but `video_player` has no HLS there, so playback doesn't work |
| Linux, web | No in-app sign-in; paste the cookie manually. Linux has the same HLS gap as Windows |

## Be a good citizen

This is a university service with real running costs. Don't scrape whole
semesters in a loop, leave the caching and error backoff in place, and honour
course visibility — if TUM-Live won't show you something signed out, neither
should this.

## Contributing

Architecture, the API in use, the test suite, and notes on TUM-Live's server
internals are all in [DESIGN.md](DESIGN.md). Read it before changing anything.

## License

See [LICENSE](LICENSE).
