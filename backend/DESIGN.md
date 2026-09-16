# TUM Live client — backend design

Notes from reading [TUM-Dev/gocast](https://github.com/TUM-Dev/gocast) and probing the
live server at `tum.live`. Everything marked *verified* was checked against the real API
on 2026-09-07.

## The headline: gocast already ships the backend

gocast has a documented public REST API — **API v2** — built from
[`apiv2/server/apiv2.proto`](https://github.com/TUM-Dev/gocast/blob/dev/apiv2/server/apiv2.proto)
via gRPC + grpc-gateway. Its own README calls it "a user-friendly and easy-to-use
interface for third party services … access to all non-administrative features".

- Base URL: `https://tum.live/api/v2`
- Swagger docs: `https://tum.live/api/v2/docs`
- Verified live: `GET /api/v2/status` → `{"status":"OK"}`

For a read-only lecture player, **there is almost nothing left to build server-side.**
Write the Flutter app against v2 directly and only add our own service where v2 has a
real gap (see "What a backend would actually be for").

## Endpoint map (from the proto, paths relative to `/api/v2`)

| Purpose | Method + path |
|---|---|
| Health | `GET /status` |
| Frontend config / branding | `GET /config` |
| Semester list + current | `GET /semesters` |
| Public course listing | `GET /courses?year=2025&term=W` |
| **Course + all its lectures** | `GET /courses/{slug}?year=&term=` |
| My enrolled courses | `GET /courses/enrolled?year=&term=` |
| Pinned courses | `GET /courses/pinned` |
| Currently live | `GET /courses/live` |
| Pin / unpin | `GET`/`POST /courses/{course_id}/pin` |
| **One lecture (signed playlist URLs)** | `GET /streams/{slug}/{stream_id}` |
| Chapter markers | `GET /streams/{slug}/{stream_id}/sections` |
| Subtitles (VTT) | `GET /streams/{slug}/{stream_id}/subtitles/{lang}` |
| Thumbnail sprite | `GET /streams/{slug}/{stream_id}/thumbs` |
| Up-next list for a course | `GET /streams/{slug}/{stream_id}/playlist` |
| **Watch progress, batch read** | `GET /progress?stream_ids=…` |
| **Watch progress, write** | `PATCH /progress/{stream_id}` `{progress: float, watched: bool}` |
| Bookmarks | `GET`/`POST /bookmarks`, `PUT`/`DELETE /bookmarks/{id}` |
| Me | `GET /users/me` |
| Settings | `PATCH /users/settings` |
| Login options | `GET /login-options` |
| Notifications | `GET /notifications`, `GET /server-notifications` |

`progress` and `bookmarks` are the ones that make this feel like YouTube/Bilibili —
resume-where-you-left-off and a watched marker are server-side already, synced across
devices, no database of our own required.

## How the video URL actually works

`tools.SetSignedPlaylists` in
[`tools/stream-signing.go`](https://github.com/TUM-Dev/gocast/blob/dev/tools/stream-signing.go)
mints an **RS256 JWT valid for 7 hours** and appends it as `?jwt=` to the playlist URL.
Claims: `UserID`, `Playlist`, `Download`, `StreamID`, `CourseID`.

Consequences for the client:

1. **Never persist a playlist URL.** It rots in 7 hours. Cache the *stream id + course
   slug*, and re-fetch `GET /streams/{slug}/{stream_id}` right before playback. That is
   the single most important design rule for this app — and the reason the hardcoded
   link in `main.dart` keeps dying.
2. Every course/stream response already carries freshly signed URLs, so one request
   gives you a playable list. *Verified:* `GET /courses/WiSe25VKM?year=2025&term=W`
   returns 9 lectures, each with a live `playlistUrl` + `hlsUrl`.
3. Three variants exist per lecture: `playlistUrl` (COMB), `playlistUrlCam` (CAM),
   `playlistUrlPres` (PRES) — that's the camera/slides source switcher.
4. The edge server is `edge.live.rbg.tum.de`; it validates the JWT itself. We cannot
   sign these — only gocast holds the key. No proxy of ours can shortcut this.

## The one real problem: authentication

*Verified:* `GET /login-options` → `{"useSaml":true,"idpName":"TUM Login","idpColor":"#3070B3"}`.
tum.live authenticates via **SAML SSO**, not a username/password JSON endpoint.

The flow, from `web/saml.go`, `web/user.go` and `tools/session.go`:

```
GET /saml/out  →  TUM IdP  →  SAML assertion POSTed back  →  gocast StartSession()
   → sets HttpOnly cookie  jwt=<RS256, 7-day TTL>
POST /api/v2/auth/token   (with that cookie)
   → { "access_token": "...", "token_type": "Bearer", "expires_in": 900 }
Authenticated calls:  Authorization: Bearer <access_token>
```

*Verified:* `POST /api/v2/auth/token` without a cookie → `401`.

`POST /login` with `username`/`password` form fields also exists, but it only works for
local accounts and LDAP-enabled deployments — on tum.live SAML is the path. Don't build
a credential form; you'd be phishing your own users and it wouldn't work anyway.

Anonymous access still gets you every `visibility: "public"` course, playlists included.
Courses scoped `loggedin`/`enrolled` — which is most of the ones you actually
want — need the bearer token.

## Two architectures

### A. No backend — client talks to tum.live directly *(recommended start)*

```
Flutter app ──HTTPS──> tum.live/api/v2        (metadata, progress, bookmarks)
     │
     └──HLS + ?jwt──>  edge.live.rbg.tum.de   (video)
```

Login: open `https://tum.live/saml/out` in `flutter_web_auth_2` /
`ASWebAuthenticationSession` / a `webview_flutter` sheet, let the user do TUM SSO, then
capture the `jwt` cookie from the webview cookie jar. Store it in
`flutter_secure_storage`. Exchange it at `/api/v2/auth/token` on app start and every
~13 minutes; keep the bearer in memory only.

- **Pros:** zero infrastructure, zero cost, no privacy liability, always in sync with
  upstream, progress/bookmarks sync for free.
- **Cons:** the SSO cookie capture is the fiddly part; a tum.live API change breaks
  shipped clients; no offline/caching layer; no push notifications.

### B. Thin backend (BFF / token broker) — add when A hurts

```
Flutter app ──> our API ──> tum.live/api/v2
                   │
                   └── Postgres/SQLite: our own extras
```

Our service would be a small Go or FastAPI process that:

- **Owns the OAuth-ish dance.** Hosts the redirect target, holds the gocast session
  cookie server-side, and hands the app *our* refresh/access token pair. The app never
  touches a webview cookie jar. This alone is the strongest argument for a backend.
- **Caches course/semester listings** (Redis, 5–15 min TTL). Never cache playlist URLs.
- **Fans out push notifications** for "your lecture just went live" — poll
  `/courses/live` on a cron, push via FCM/APNs. v2 has no push and no websocket for us.
- **Serves a client-shaped payload.** One `GET /home` that merges pinned + enrolled +
  live + continue-watching, instead of the app making five calls on cold start.
- **Full-text search across lectures** including subtitles — gocast has Meilisearch but
  its search route is on the old v1 admin API, not v2.
- **Offline/download bookkeeping** — which lectures a user grabbed, on which device.
- **Version shim.** When tum.live changes, we patch the server, not the App Store build.

Do **not** proxy video through it. Bandwidth cost, latency, and the edge JWT is bound to
the user anyway.

### Recommendation

Build A now — it gets a working app in days and proves the API surface. Introduce B the
moment you want push notifications or an app-store release whose auth you can fix without
shipping a new binary. The code split makes this cheap: put every network call behind a
`TumLiveApi` interface in Dart, and B becomes a base-URL change plus a new auth impl.

## Client-side shape (Flutter)

```
lib/
  api/         tum_live_client.dart      # dio + interceptor that refreshes the bearer
               models/                   # Course, Stream, Semester, StreamProgress…
  auth/        sso_session.dart          # webview SSO -> jwt cookie -> access token
  features/
    home/      pinned + live + continue watching
    course/    lecture list for a slug
    player/    the existing player, fed a stream_id (NOT a URL)
  player/      controls (already written — keep, it's the good part)
```

Generate the models straight from `apiv2.proto` (`protoc` + `protoc-gen-dart`), or hand-
write them from the JSON — the gateway emits lowerCamelCase JSON, e.g. `playlistUrl`,
`lastRecording`, `isPubliclyVisible`.

### Playback caveat

`video_player` handles HLS via AVPlayer (iOS/macOS) and ExoPlayer (Android). On Windows
and Linux there is no HLS support, and on web it depends on the browser. If desktop
matters, swap to `media_kit` (libmpv) — same widget-level API surface, real HLS
everywhere.

## Milestones

1. **Kill the hardcoded URL.** Player takes `(courseSlug, streamId)`, fetches
   `GET /streams/{slug}/{id}` and plays `playlistUrl`. Public course, no auth.
2. **Browse.** `/semesters` + `/courses` → course grid → lecture list.
3. **Sign in.** SAML webview → cookie → `/auth/token` → bearer interceptor with refresh.
   Now `/courses/enrolled` and `/courses/pinned` light up.
4. **Feel like YouTube.** `PATCH /progress/{id}` every ~5 s, resume on open, watched
   badges, "continue watching" row on home.
5. **Polish.** `/sections` as chapter markers, `/thumbs` sprite for seek preview,
   `/subtitles/{lang}`, CAM/PRES/COMB source switcher, PiP, background audio.
6. **Then decide on a backend** (option B), driven by whichever of push / search /
   offline you actually want.

## Be a good citizen

This is a university service with real costs. Cache aggressively, back off on errors,
send a descriptive `User-Agent`, don't scrape whole semesters in a loop, and honour
course visibility — `visibility: "hidden"` and non-public lectures exist for a reason.
Worth opening an issue on TUM-Dev/gocast to say you're building a client; they wrote v2
precisely for third-party apps and are likely to help.

---

# Part 2 — how gocast works, cut detection, and login

## How gocast is put together

It is not one program. From the README's architecture diagram and the repo layout:

| Component | What it is |
|---|---|
| `cmd/tumlive` | The main server. Gin + GORM on MariaDB. Serves the website, the v1 REST API (`api/`), the v2 gRPC+gateway API (`apiv2/`), chat websockets, Meilisearch queries. Holds the RSA key that signs every JWT. |
| `worker/` | Separate machines near the lecture halls. Connected to the main server by **gRPC — the server pushes jobs to them**. They pull RTSP from cameras/Extron devices, transcode with ffmpeg, cut thumbnails, run silence detection, upload the result. |
| `runner/` | The newer generation of `worker` (`runner.proto`, `hls.go`). Same role, being migrated to. |
| `ingest/` + `rtmp-proxy/` | RTMP endpoints for lecturers streaming from home with OBS. Stream keys are handed out via `POST /api/token/proxy/:token`. |
| `vod-service/` | Takes an uploaded mp4 over HTTP, packages it into `playlist.m3u8` + `segmentNNNN.ts`. No re-encoding. |
| `worker/edge/` | The CDN. Caches immutable segments and proxies the rest. **This is what validates `?jwt=`.** |
| `pkg/campus` | CAMPUSOnline/TUMonline integration — imports courses, schedules, enrolments. This is why access control works without anyone maintaining it by hand. |
| Identity | SAML (TUM Login) and optionally LDAP, feeding into the user table. |

### One lecture, end to end

1. CAMPUSOnline says a lecture happens Tuesday 10:00 in room X. gocast schedules a stream.
2. At 10:00 the server sends a gRPC job to a worker. The worker pulls RTSP from the camera and the HDMI/slides feed, produces COMB / CAM / PRES, and pushes HLS out live.
3. At the end, the worker transcodes the recording, generates thumbnails, **runs silence detection**, and uploads to shared storage + `vod-service`, which packages it to HLS.
4. A student opens the lecture. The server checks enrolment, then calls
   `tools.SetSignedPlaylists` — a **7-hour RS256 JWT** per playlist variant, appended as `?jwt=`.
5. The player requests that m3u8 from an edge node. Edge verifies the signature, checks
   the `Playlist` claim matches the requested path, and — this detail matters —
   **rewrites the playlist so every `.ts` segment carries the same `?jwt=`**
   (`worker/edge/edge.go:232,258`), so each segment is authorised too.

The consequence for us: the server's job is deciding *whether you may watch* and signing
a short-lived ticket. Bytes never go through it. That is exactly the part we cannot and
should not rebuild.

## Can it really all be client-side?

For **browsing, playback, progress and bookmarks — yes**, all of it. Verified against the
live server. The honest limits:

- No push notifications. There is no mechanism for a third-party app to be woken.
- No search across lectures in v2 (gocast has Meilisearch, but only on the v1 admin API).
- Nothing is cached; every cold start hits tum.live.
- A breaking upstream change means shipping a new binary.
- **Cut detection is impossible client-side at reasonable cost** — see below.

## Skipping dead time (black screen / silence)

### What gocast already has, and why you can't use it

`worker/worker/silence.go` runs, after transcoding:

```
ffmpeg -nostats -i <input> -af silencedetect=n=-15dB:d=30 -f null -
```

It parses `silence_start` / `silence_end`, merges nearby runs, and stores
`model.Silence{Start, End, StreamID}` (whole seconds).

But that data is **not exposed by any client API** — not in `apiv2.proto`, not in
`api/stream.go`. Its only consumer is `Stream.FirstSilenceAsProgress()`, used in
`web/watch.go:112` to nudge your initial progress past the dead time at the *start* of a
recording. That is the whole feature.

Note also `d=30` — it only records silences **30 seconds or longer**. Useful for "skip the
5 minutes before the lecturer starts", useless for tightening up pauses mid-lecture.

### What tum_video_scraper does

`src/downloader.py` downloads with `ffmpeg -c copy`, then:

```
auto-editor <input> --silent_speed 8 --video_codec h264 --no_open -o <output>_jc.mp4
```

It is **audio**-based (silence), not black-frame based, and it **re-encodes the whole
video** to produce a new file. That is fine for a download-and-archive tool. It is the
wrong shape for a streaming player: minutes of CPU per lecture, and you must have the
whole file first.

### The right design for a player: a cut list, not a new video

Don't produce a new video. Produce **a list of ranges to skip**, and let the player skip
them at playback time:

```json
{ "streamId": 12345, "version": 1, "source": "COMB",
  "cuts": [ {"start": 0,    "end": 312,  "kind": "black"},
            {"start": 1840, "end": 1907, "kind": "silence"} ] }
```

In Flutter this is a few lines against the existing controller — on each position tick,
if you are inside a cut, either `seekTo(cut.end)` or `setPlaybackSpeed(8)` until you leave
it (auto-editor's behaviour, less jarring). Zero re-encoding, works while streaming,
instantly toggleable, and the user can turn it off.

Generating the list needs ffmpeg over the media, so **this is the feature that actually
justifies a backend.** Doing it on-device would mean shipping `ffmpeg_kit_flutter` and
downloading each lecture before watching it — which defeats the point.

### Cut-detection service sketch

```
POST /cuts/{streamId}        # request analysis (idempotent, queued)
GET  /cuts/{streamId}        # -> cut list, or 202 while pending
```

A worker pulls the HLS and runs one ffmpeg pass with both filters:

```
ffmpeg -i "<playlist.m3u8?jwt=…>" \
  -vf "scale=160:-2,blackdetect=d=2:pic_th=0.98" \
  -af "silencedetect=n=-30dB:d=3" \
  -f null - 2>&1
```

Then parse `black_start/black_end` and `silence_start/silence_end` from stderr, intersect
or union them per your taste, and drop cuts shorter than ~2 s (skipping those feels like
a glitch).

Things that make this cheap:

- **Analyse once, serve everyone.** Key the cache by `streamId` + source. The first
  student to open a lecture pays; the rest get it instantly. This is the single biggest
  argument for a server over on-device: the work is shared.
- Use the **lowest-bitrate HLS variant**, scale to 160px, and `-r 1` for black detection.
  You are looking for black frames and quiet, not quality.
- For silence you can drop video entirely (`-vn`) — that pass is very fast.
- Results are immutable once a lecture has ended. Store them forever; they're tiny.
- Tune thresholds: gocast's `-15dB / 30s` is deliberately conservative. `-30dB / 3s` is
  closer to what a "skip the pauses" toggle should feel like. Make it configurable and
  let the client choose a preset.

Fair warning: the analysis job needs a valid playlist JWT, so the request has to carry the
user's token or the service needs its own session. Keep the analysis worker inside your
own trust boundary and never log the JWTs.

## Login, concretely

`GET /api/v2/login-options` → `{"useSaml":true,"idpName":"TUM Login","idpColor":"#3070B3"}`.
So: SAML only. `POST /login` with username/password exists in `web/user.go` but serves
local and LDAP accounts; on tum.live it will not get you in. **Do not build a
username/password form** — it won't work, and it trains users to type their TUM password
into a third-party app.

### Flow (client-only version)

```
1.  Open a WebView at  https://tum.live/saml/out
2.  User authenticates with the TUM IdP (2FA and all, in a real browser context)
3.  IdP POSTs the SAML assertion back; gocast calls StartSession() and sets
        Set-Cookie: jwt=<RS256, 7 days>; Path=/; Secure; HttpOnly
    then redirects to "/"
4.  Detect that redirect (host == tum.live, path no longer under /saml/) -> flow done
5.  Read the `jwt` cookie from the WebView's NATIVE cookie store
6.  Store it in flutter_secure_storage
7.  POST https://tum.live/api/v2/auth/token   with that cookie
        -> {"access_token": "...", "token_type": "Bearer", "expires_in": 900}
8.  Dio interceptor puts  Authorization: Bearer <token>  on every call,
    re-minting at ~13 min or on the first 401
9.  Cookie dies after 7 days -> send the user back through step 1
```

Step 5 is the one thing to prove before committing to this design. The cookie is
`HttpOnly`, so `document.cookie` in JS will never see it — but the platform cookie stores
(`android.webkit.CookieManager`, `WKHTTPCookieStore`) do expose HttpOnly cookies, and
`webview_cookie_manager` / `flutter_inappwebview` read from those. Spike it first.

**Fallback if that fails:** never extract the cookie at all. Keep a persistent (offscreen)
WebView and, whenever you need a token, run inside it:

```js
fetch('/api/v2/auth/token', {method:'POST', credentials:'include'})
  .then(r => r.json()).then(j => TokenChannel.postMessage(j.access_token))
```

The cookie is attached automatically by the WebView; you receive only the 15-minute bearer
over a JS channel. Slightly clumsier, but immune to HttpOnly entirely.

### Later: move it into the backend

Once the backend exists, it hosts the SAML redirect target, keeps the gocast session
cookie server-side, and issues your app its own refresh/access pair. The app then never
touches a WebView cookie jar, and when tum.live changes its auth you fix a server, not an
App Store build. Same reason the cut service wants to be a server: do the awkward work
once, centrally.

## Revised recommendation

The earlier "you don't need a backend" holds for **v1 of the app** — browsing, playback,
progress, bookmarks. But black-screen/silence skipping is a genuine server feature, and
it happens to be the one that makes your app better than tum.live's own player rather than
just a re-skin. So:

- **Phase 1 (no backend):** milestones 1–5 above, client-only, SSO in a WebView.
- **Phase 2 (small backend):** cut-detection service first — it's self-contained, it's the
  differentiator, and it needs nothing else. `POST /cuts/{id}`, `GET /cuts/{id}`, a job
  queue, ffmpeg, and a cache. Add the auth broker and push notifications afterwards, onto
  the same service.
