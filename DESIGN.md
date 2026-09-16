# Design notes

How this client is put together, how TUM-Live's server works underneath it, and
the design for the one feature that would need a backend of our own.

`README.md` is for people who want to *use* the app. Everything a contributor
needs is here.

Facts about gocast below were checked against its source and the live server.

---

# Part 1 — This app

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

There is also a CLI that hits the real API and prints what comes back:

```bash
dart run tool/api_smoke.dart
```

---

## Tests

```bash
flutter test          # 68 tests, no network
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
   backend of our own. See Part 3 below.

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

---

# Part 2 — gocast internals

## How gocast is put together

TUM-Live is not one program. From its README's architecture diagram and layout:

| Component | What it is |
|---|---|
| `cmd/tumlive` | The main server. Gin + GORM on MariaDB. Serves the website, the v1 REST API (`api/`), the v2 gRPC+gateway API (`apiv2/`), chat websockets, Meilisearch queries. Holds the RSA key that signs every JWT. |
| `worker/` | Separate machines near the lecture halls. The server pushes them jobs over gRPC. They pull RTSP from cameras and slide feeds, transcode with ffmpeg, cut thumbnails, run silence detection, upload. |
| `runner/` | The newer generation of `worker` (`runner.proto`, `hls.go`). Same role, being migrated to. |
| `ingest/`, `rtmp-proxy/` | RTMP endpoints for lecturers streaming from home with OBS. |
| `vod-service/` | Takes an uploaded mp4 over HTTP, packages it into `playlist.m3u8` + `segmentNNNN.ts`. No re-encoding. |
| `worker/edge/` | The CDN. Caches immutable segments, and **validates `?jwt=`**. |
| `pkg/campus` | CAMPUSOnline/TUMonline integration — imports courses, schedules, enrolments. Why access control works without anyone maintaining it by hand. |

### One lecture, end to end

1. CAMPUSOnline says a lecture happens Tuesday 10:00 in room X. gocast schedules it.
2. At 10:00 the server sends a gRPC job to a worker, which pulls RTSP from the
   camera and the slides feed and produces COMB / CAM / PRES.
3. Afterwards the worker transcodes, generates thumbnails, **runs silence
   detection**, and uploads to `vod-service`, which packages it to HLS.
4. A student opens the lecture. The server checks enrolment, then calls
   `tools.SetSignedPlaylists` — a 7-hour RS256 JWT per playlist variant,
   appended as `?jwt=`.
5. The player requests that m3u8 from an edge node. Edge verifies the signature,
   checks the `Playlist` claim matches the requested path, and **rewrites the
   playlist so every `.ts` segment carries the same `?jwt=`**
   (`worker/edge/edge.go`), so each segment is authorised too.

The server's whole job is deciding *whether you may watch* and signing a
short-lived ticket. Video bytes never pass through it. That is the part we
cannot and should not rebuild — and why a client-only app works at all.

### Session mechanics

- `StartSession` is called in exactly two places, both login moments
  (`web/user.go`, `api/users.go`).
- `InitContext`, the middleware on every request, parses and validates the
  cookie but **never re-issues it**. The only other `SetCookie("jwt", …)` calls
  in that file *delete* it.

So the session is a hard 7 days with no sliding window. What makes a browser
appear logged in for months is SSO chaining: when gocast's cookie lapses, the
request bounces to the TUM identity provider, which has its own much longer
session, and comes back with a fresh assertion — no password typed. See
[How sign-in works](#how-sign-in-works) for how the app inherits that.

---

# Part 3 — Skipping dead time (black screen / silence)

The feature that would make this app better than tum.live's own player, rather
than a re-skin. Also the only one that genuinely needs a server.

## What gocast already has, and why you can't use it

`worker/worker/silence.go` runs, after transcoding:

```
ffmpeg -nostats -i <input> -af silencedetect=n=-15dB:d=30 -f null -
```

It parses `silence_start` / `silence_end`, merges nearby runs, and stores
`model.Silence{Start, End, StreamID}` in whole seconds.

That data is **not exposed by any client API** — not in `apiv2.proto`, not in
`api/stream.go`. Its only consumer is `Stream.FirstSilenceAsProgress()`, used in
`web/watch.go` to nudge your initial progress past the dead air at the *start* of
a recording. That is the whole feature.

Note `d=30`: it only records silences 30 seconds or longer. Useful for "skip the
five minutes before the lecturer starts", useless for tightening mid-lecture
pauses.

## What tum_video_scraper does

[Valentin-Metz/tum_video_scraper](https://github.com/Valentin-Metz/tum_video_scraper)
downloads with `ffmpeg -c copy`, then:

```
auto-editor <input> --silent_speed 8 --video_codec h264 --no_open -o <out>_jc.mp4
```

It is **audio**-based, not black-frame based, and it **re-encodes the whole
video**. Fine for archiving; wrong shape for a player — minutes of CPU per
lecture, and you need the whole file first.

## The right design: a cut list, not a new video

Don't produce a new video. Produce a list of ranges to skip:

```json
{ "streamId": 12345, "version": 1, "source": "COMB",
  "cuts": [ {"start": 0,    "end": 312,  "kind": "black"},
            {"start": 1840, "end": 1907, "kind": "silence"} ] }
```

In Flutter that is a few lines against the existing controller: on each position
tick, if you are inside a cut, either `seekTo(cut.end)` or `setPlaybackSpeed(8)`
until you leave it. No re-encoding, works while streaming, instantly toggleable.

## Service sketch

```
POST /cuts/{streamId}   # request analysis (idempotent, queued)
GET  /cuts/{streamId}   # -> cut list, or 202 while pending
```

A worker pulls the HLS and runs one ffmpeg pass with both filters:

```
ffmpeg -i "<playlist.m3u8?jwt=…>" \
  -vf "scale=160:-2,blackdetect=d=2:pic_th=0.98" \
  -af "silencedetect=n=-30dB:d=3" \
  -f null - 2>&1
```

Parse `black_start/black_end` and `silence_start/silence_end` from **stderr**,
then drop cuts shorter than ~2 s — skipping those feels like a glitch.

What makes it cheap:

- **Analyse once, serve everyone.** Key the cache by `streamId` + source. The
  first student to open a lecture pays; the rest get it instantly. This shared
  work is the real argument for a server over on-device ffmpeg.
- Use the lowest-bitrate HLS variant, scale to 160px, `-r 1` for black detection.
- For silence, drop video entirely (`-vn`) — that pass is very fast.
- Results are immutable once a lecture has ended. Store them forever; tiny.
- gocast's `-15dB / 30s` is deliberately conservative. `-30dB / 3s` is closer to
  what a "skip the pauses" toggle should feel like. Make it configurable.

The analysis job needs a valid playlist JWT, so the request carries the user's
token. Keep the worker inside your own trust boundary and never log the JWTs.

## What a backend should *not* do

- **Proxy video.** Bandwidth, latency, and the edge JWT is bound to the user.
- **Broker authentication.** Renewing a gocast session needs a live IdP session,
  which lives in a browser cookie jar on the user's device. A server cannot hold
  or impersonate it, so a broker would hit the hard 7-day wall with no way to
  renew silently — strictly worse than the WebView the app already uses.

Other things a backend *would* earn its keep on, later: push notifications for
"your lecture just went live" (poll `/courses/live` on a cron), full-text search
across lectures including subtitles, and offline-download bookkeeping.
