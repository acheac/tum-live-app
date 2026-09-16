# gocast internals, and the one thing worth a backend

Reference notes for the TUM-Live server this client talks to, plus the design for
the only feature that would genuinely need a backend of our own.

Everything about *our* app — architecture, auth, endpoints, current state — is in
`README.md`. This file is only what didn't fit there.

Facts below were checked against the gocast source and the live server.

---

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
`README.md` for how the app inherits that.

---

## Skipping dead time (black screen / silence)

The feature that would make this app better than tum.live's own player, rather
than a re-skin. Also the only one that genuinely needs a server.

### What gocast already has, and why you can't use it

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

### What tum_video_scraper does

[Valentin-Metz/tum_video_scraper](https://github.com/Valentin-Metz/tum_video_scraper)
downloads with `ffmpeg -c copy`, then:

```
auto-editor <input> --silent_speed 8 --video_codec h264 --no_open -o <out>_jc.mp4
```

It is **audio**-based, not black-frame based, and it **re-encodes the whole
video**. Fine for archiving; wrong shape for a player — minutes of CPU per
lecture, and you need the whole file first.

### The right design: a cut list, not a new video

Don't produce a new video. Produce a list of ranges to skip:

```json
{ "streamId": 12345, "version": 1, "source": "COMB",
  "cuts": [ {"start": 0,    "end": 312,  "kind": "black"},
            {"start": 1840, "end": 1907, "kind": "silence"} ] }
```

In Flutter that is a few lines against the existing controller: on each position
tick, if you are inside a cut, either `seekTo(cut.end)` or `setPlaybackSpeed(8)`
until you leave it. No re-encoding, works while streaming, instantly toggleable.

### Service sketch

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

### What a backend should *not* do

- **Proxy video.** Bandwidth, latency, and the edge JWT is bound to the user.
- **Broker authentication.** Renewing a gocast session needs a live IdP session,
  which lives in a browser cookie jar on the user's device. A server cannot hold
  or impersonate it, so a broker would hit the hard 7-day wall with no way to
  renew silently — strictly worse than the WebView the app already uses.

Other things a backend *would* earn its keep on, later: push notifications for
"your lecture just went live" (poll `/courses/live` on a cron), full-text search
across lectures including subtitles, and offline-download bookkeeping.
