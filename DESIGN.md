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
    brand.dart                  TUM's blue, for surfaces that must not be themed
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
      lecture_player.dart       owns the VideoPlayerController(s)
      player_controls.dart      control bar, gestures, camera inset
      player_preferences.dart   remembered camera angle and inset position
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

### Why the player is split up

They fail differently, and splitting them is what keeps the tests cheap:

- `player_controls.dart` — pure UI over an initialised controller.
- `lecture_player.dart` — owns the `VideoPlayerController`: load, fail, retry.
  Takes a plain URL, so widget tests drive it with a fake platform and no HTTP.
- `player_page.dart` — the only part that knows TUM-Live exists.
- `player_preferences.dart` — choices that outlive one lecture.

### The gesture model

The picture takes all three touch gestures on one surface, which makes Flutter's
gesture arena the interesting part of `player_controls.dart`:

```
tap              show or hide the controls
double tap       play / pause, leaving the controls exactly as they were
swipe sideways   scrub, with the bar raised and the target time in the centre
```

Three decisions there are load-bearing, and all three were arrived at the hard
way:

- **`GestureDetector.onDoubleTap` is not used.** It withholds the single tap for
  `kDoubleTapTimeout` to find out whether a second is coming, so the controls
  appeared a third of a second after the finger lifted — long enough to feel
  broken. Pairs are detected by hand instead, with a 250ms window, and the tap
  waits that out rather than acting and undoing itself. Acting immediately made
  a double tap flash the bar up and pull it straight back.
- **The gesture surface sits *under* the chrome in the Stack**, so a tap that
  lands on a control is absorbed by that control. Wrapping the chrome in it
  starves descendant buttons: the play button stopped responding entirely.
- **A drag must travel 8px before it counts as a scrub.** The drag recognizer
  can win a gesture that never moves — including a plain tap on a control — and
  firing start/end on that paused and resumed the video on every tap.

### Fused mode (beta)

gocast's combined recording packs the slides and the camera into one 16:9 frame
and pads the rest with black. Measured on a real lecture at 2352×1080: content
occupied x 380–2187 and stopped at y 805, so roughly a quarter of the frame is
padding the player cannot fit away, because it is *in the video*.

`LectureSource.fused` composites on the device instead — the slides as the full
picture, with the camera as a draggable, resizable inset. It is the one source
the server does not have, and it needs both a slides and a camera track.

Two decoders at once has one non-obvious cost: **both players request exclusive
audio focus, and each one starting takes it from the other**. media3 pauses on a
permanent focus loss, so the two streams stalled each other dead — `logcat`
showed `onAudioFocusChange(-1)` alternating while both decoders sat at
`inputFps=0`. The camera is created with `VideoPlayerOptions(mixWithOthers:
true)`, which declines focus; muting it is not the same thing. Note that
`setMixWithOthers` is a **single global flag read at player creation**, not a
per-player setting, so creation order matters and the main controller states its
own value explicitly.

Sync is two mechanisms, deliberately: play/pause and speed are matched the
instant the main controller reports them, while position drift is corrected on a
2s timer and only past 400ms. Seeking on every position tick stutters both.

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

**Signing out has to fight that same mechanism.** Deleting gocast's cookie is not
enough: the next request renews through `/saml/out`, the IdP session being
untouched and far longer-lived, and the user is silently signed back in — often
before they notice, since `TumLiveApi` mints a token ahead of *every* request,
public courses included. So `clear()` wipes the entire cookie jar rather than
just tum.live's, and sets a flag that blocks silent renewal until a token comes
back on its own — which only happens once the user has been through the login
page again. Note this logic lives in `WebViewTokenSource` and needs a real
WebView, so it is **not covered by the test suite**; verify it by hand on a
device after touching it.

That flag is harder to hold than it looks, and it failed in two ways on a real
device — both found by polling the WebView's cookie database through
`adb run-as` while signing out. `bearerToken()` abandons a slow mint after three
seconds but lets it keep running, so a round trip begun *before* the sign-out
finished *after* it, found a token, and cleared the very flag meant to stop it;
and `clear()` left the WebView running, so a SAML round trip already in flight
landed its `Set-Cookie` on the far side of the delete. A fresh `jwt` appeared
about four seconds after every sign-out. `clear()` now bumps a generation
counter that stale mints check against, and disposes the WebView *before*
touching the jar.

**`CookieTokenSource`** (Linux, web) is the fallback where no WebView exists:
the user copies the `jwt` cookie from a browser. This path *does* store the
cookie via `SharedPreferences`, which is plain text — swap
`SharedPreferencesCredentialStore` for a `flutter_secure_storage` implementation
of the same interface before shipping on those platforms.

---

**A platform view outlives the widgets stacked over it.** Signing in used to
flash TUM-Live's website on the *home* screen, under the home app bar, after
the login page had closed. The cover over the WebView is a Flutter widget; the
WebView is an Android platform view, and while a route animates away the two
stop agreeing about z-order — the page draws straight over the cover. So the
login page takes the WebView out of the tree, waits for that frame, and only
then pops. Hiding it is not enough: a platform view still in the tree still
draws.

Two wrong turns on the way, both worth not repeating. "Look for a bright frame"
found nothing across 131 captures, because TUM's login page follows the system
dark theme — the flash is not white. And `HeadlessInAppWebView` looks like an
excellent suspect, since "headless" means *no Flutter widget*, not invisible,
and it defaults to `Size(-1, -1)` — MATCH_PARENT. It is innocent: the Android
source calls `setVisibility(View.INVISIBLE)` and adds it at index 0, behind
Flutter. Read that source before blaming it.

What settled it was a burst of `adb` screencaps through a real sign-in and then
*looking* at the frames, after the measurements said nothing.

**The sign-in transitions are asymmetric, and have to be.** The login route
cross-fades rather than sliding, because a platform view does not slide with
the route it sits in — it lags the Flutter content and arrives with a snap.
Inside the page the cover fades out over 220ms but goes up in 0: uncovering has
nothing to hide, while fading *in* over a live page would show that page
through a half-transparent cover for the length of the fade, which is the flash
again at quarter speed. Any future animation here inherits that rule — hiding
is instant, revealing is gradual.

## API endpoints in use

Relative to `https://tum.live/api/v2`. Full list at `/api/v2/docs`.

| Purpose | Endpoint |
|---|---|
| Semester list + current | `GET /semesters` |
| Public course listing | `GET /courses?year=&term=` |
| Course + all its lectures | `GET /courses/{slug}?year=&term=` |
| Enrolled / pinned / live | `GET /courses/enrolled`, `/courses/pinned`, `/courses/live` |
| Pin / unpin | `POST /courses/{id}/pin` with `{"pin": bool}` |
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

**The published swagger is stale about pinning.** `GET /api/v2/docs/swagger.json`
documents `GET/POST /user/pinned` and `DELETE /user/pinned/{courseID}`. None of
those exist on the deployed server — all three answer 404, while the
`/courses/pinned` and `/courses/{id}/pin` this app uses answer 401, which is an
endpoint that exists and wants a token. Probe with an unauthenticated `curl` and
read 401 as "real, needs auth" before believing the spec over the server.

Pins are server-side only; nothing about them is stored on the device. The home
screen fetches them once per load, so a pin made elsewhere — the TUM-Live
website in a browser, say — shows up only after something refetches: pull to
refresh, a semester change, signing in or out, or a pin made in the app (see
`pinRevision`).

## Tests

```bash
flutter test          # 111 tests, no network
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

Two more from the same family, both silent, both found only by reading the code
around a change rather than by any failing test:

- `_reportProgress(force: true)` passed no duration, so the next line computed a
  fraction against zero and returned early. **The final progress write on
  leaving a lecture had never once fired.**
- `_load()` seeds the resume position with `??=`, so switching lecture without
  clearing it would have opened the new lecture at the *previous* one's
  timestamp.

---

## Current state

**Works:** browsing by semester, course lists with search, lecture lists with
watch-progress bars, playback with resume, progress sync, camera-angle
switching (remembered between lectures and launches), playback speed,
fullscreen, fused mode, and sign-in on WebView platforms.

**The home screen searches in memory, and shows public courses five at a
time.** How many courses `/courses` returns depends on who is asking:
unauthenticated it serves only `public` ones, which across all eighteen
semesters the API knows peaks at 20 (W2022, a 77 KB response), but signed in it
also returns everything a TUM account may see — SS 2024 comes back with 75.
Either way it is one request whose result is already in memory, so filtering is
a `where` over a loaded list, with no round trip and no debounce.

Worth knowing when measuring this API: a `curl` without a session will
understate every course count by roughly four times, which is how the
twenty-course figure above got quoted as the maximum at first. `foldForSearch` in `common/course_search.dart` strips German
diacritics from both the query and the name, because an English phone keyboard
cannot type the `ü` in *Einführung* and the catalogue is full of them.

**Live now is narrowed to the user's own courses.** `/courses/live` returns
every stream running anywhere on TUM-Live, and the section sits above
everything else on the home screen — in term that is a column of other people's
lectures before the user reaches their own. Signed in it keeps only courses
that are enrolled or pinned. Signed out it is left alone: there is no "their
own" to narrow to, and anything a signed-out user can see live is public
anyway, so filtering would only empty the section.

Hard to try by hand — between terms `/courses/live` returns nothing at all, so
the widget tests are the only way this gets exercised.

**Pinning lives on the pages that show a course, and the pinned list lives in
the semester menu.** `common/pin_button.dart` is the one toggle, carried by the
course page's app bar (right after the name) and by the player page's row under
the picture (right end, so it falls under the fullscreen button; never in
fullscreen, where `_buildDetails` is not in the tree). The toggle is optimistic
and reverts with a message on failure — the only visible error in the app,
because the user watched the icon change. `pinRevision` is what tells the home
screen to refetch, since its pinned list is a separate request from the course
the pin was toggled on.

The pinned courses are a *view*, reached from one entry in the semester picker
rather than having a section of their own on the main list. Choosing it swaps
"My courses" for "Pinned courses" and hides live, enrolled and public entirely,
so the page reads as its own screen while staying on the same route — the
semester picker and the search field belong to both views, and pushing a real
page would either duplicate them or leave the pinned list unsearchable. The
same menu entry toggles back. That sharing is also why the picker is a
`PopupMenuButton` rather than the `DropdownButton` it replaced: a dropdown's
label *is* its selection, so the entry would leave its own name sitting where
the semester belongs.

Hiding the other sections is what makes the shared search field honest: it
filters whatever the page is showing, so a search made from inside the pinned
list must not drag a public course back in.

Pinned courses are marked in any list by a small pin stacked over the chevron,
and that flag comes from the pinned list rather than from `Course.pinned` —
the server only sets that field on some endpoints, while the pinned list is
definitive for every course on the page.

The five-at-a-time cap is presentation, not performance: `SliverList.builder`
builds only what is on screen, so seventy-five rows cost what five do. It
exists so the landing screen is a handful of suggestions rather than a wall. The list is shuffled once per
load and the rotate button walks it in non-overlapping groups, so "another
five" is five you have not seen and pressing on eventually shows all of them; a
fresh random draw each press could repeat what was just there. The last group
is short when the count is not a multiple of five. Searching is never capped —
hiding a match behind that button is the one thing search must not do.

**Fullscreen is button-only.** The page pins landscape while it is open, so the
accelerometer never decides: rotating a phone lying on a desk used to throw a
lecture into fullscreen unasked. Back leaves fullscreen first and the lecture
second, for both the on-screen arrow and the system gesture.

**Rotation is a screen-size decision, made once.** `OrientationPolicy` in
`common/orientation.dart` wraps every route and allows portrait only below
Material's 600dp shortest side, everything above it. A phone has exactly one
use for landscape — the player's fullscreen, entered by the button — so
rotating anywhere else only ever turned a portrait list of courses sideways. A
tablet is wide enough for those lists to read either way, and is usually held
or docked in one, so there it stays on.

The screen is asked rather than the platform: one build runs on both, and a
foldable crosses the line while running, so the policy is re-applied on size
changes rather than set once at startup. Two consequences worth knowing:
`PlayerPage.dispose` restores *that policy* rather than
`DeviceOrientation.values`, which would hand rotation back switched on for the
course list the user is returning to; and on a tablet the screen can be
landscape with `_forcedFullscreen` false, so the flag and the orientation are
allowed to disagree. Nothing reads orientation to decide fullscreen, only the
flag — the same thing that lets a landscape window keep showing the lecture
list.

**Switching lecture does not rebuild the page.** Tapping a sibling changes
`_lectureId` in state and reloads only what moved; the list and heading stay put
and the previous playback keeps rendering until the next resolves. It used to
`pushReplacement` a whole new `PlayerPage`.

**Verified against a real login** (17 Sep 2026, Android, physical device): the
full SAML round trip works end to end — TUM's login page in the WebView, the
session cookie landing in the jar, `callAsyncJavaScript` minting a token from it,
and enrolled courses rendering. Both of the things this file used to flag as
likely rough edges — landing-URL detection and `callAsyncJavaScript` behaviour —
turned out fine on Android. iOS and macOS are still unproven.

**"keep me logged in" is required, not optional.** TUM's login form
(`login.tum.de`) has a checkbox below the password field, labelled exactly
`keep me logged in` in English and `angemeldet bleiben` in German — it follows
the WebView's locale, so on-screen copy naming it should name both. Leave it
unticked and the sign-in does not stick: the WebView comes back showing a
logged-in tum.live page, but no session survives for the app, `mint()` gets a
401, and `refreshSession()` reports signed-out. Observed on a real device — the
same login succeeds with the box ticked and fails without it.

The mechanism was not confirmed, but the shape fits a non-persistent session
cookie: unticked, the IdP hands back a cookie the WebView jar does not keep, so
by the time the headless view asks for a token there is nothing to send. If you
ever dig into this, that is the thing to check first.

`webview_login_page.dart` now says so on screen, twice: a reminder pinned above
TUM's own page while it is showing, and a message naming that checkbox if the
session check comes back empty. Worth keeping — the failure is completely silent
otherwise, because every layer of the token path swallows its errors and returns
null.
The app then looks hung — the WebView shows a logged-in-looking tum.live page
while `refreshSession()` correctly reports signed-out. `webview_login_page.dart`
now says so on screen instead of sitting there silently. Worth remembering when
debugging: every layer of the token path swallows its errors and returns null, so
a silent "not signed in" is the *only* symptom no matter what actually broke.

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
- **Two widget trees for one widget will remount it.** Fullscreen and the 16:9
  slot are one layout with a changing height, not two layouts, because putting
  the player at a different depth unmounted it and built a fresh
  `VideoPlayerController` — every rotation silently restarted the lecture. A
  `ValueKey` does not help; it only matches among siblings.
- **`IconButton` takes its 48×48 tap target from the theme.** Neither
  `constraints` nor `visualDensity` shrinks it; only
  `IconButton.styleFrom(tapTargetSize: shrinkWrap)` does. That one button was
  setting the whole control bar's height.
- **`PopupMenuButton`'s `offset` cannot centre a menu on its button.** Material
  anchors to whichever side of the screen has more room, so a fixed shift
  centres it on one side and pushes it further off on the other. Hand `showMenu`
  a position rect exactly as wide as the menu instead — then both branches land
  in the same place. See `showBarMenu`.
- **Nested `GestureDetector`s with the same recognizer cancel each other.** A
  detector per corner inside the one that moves the camera inset meant nothing
  moved at all. One detector, deciding from where the drag started, works.
- **Persisted UI geometry must be stored as fractions and re-clamped on read.**
  A corner that fits a landscape picture falls outside a 16:9 slot, and an inset
  parked off-screen can never be dragged back.

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
