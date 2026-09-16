# Learning path for this project

## What actually got done so far

Being honest about scope, because it changes what you need to learn:

- **One line of code changed.** The `videoLink` constant in `frontend/tumlive_player/lib/main.dart`.
- **Everything else was research and design.** Reading the gocast source, probing the live
  tum.live server, and writing `backend/DESIGN.md`.

So "understand what was done" is mostly "understand the *investigation* and the
*reasoning*", not "understand some clever code". The good news: the investigation method
is the most transferable skill here, and you can reproduce every single finding yourself
with `curl`. Nothing below requires trusting me.

---

## Tier 0 — How to read a codebase you didn't write

This is the actual skill that produced `DESIGN.md`, and it's worth learning before any
specific technology.

The method, in the order I used it on gocast:

1. **Read the README first, especially any architecture diagram.** gocast's README has an
   ASCII diagram showing Website / Worker / Edge / VoD-Service / CAMPUSOnline. Five
   minutes there saved an hour of guessing.
2. **List directories before opening files.** `worker/`, `runner/`, `edge/`, `apiv2/`
   told me the shape of the system before I read a line of Go.
3. **Follow the nouns you care about.** I wanted "where does the video URL come from?" →
   grep for `playlist` → `SetSignedPlaylists` → `tools/stream-signing.go`. One function,
   and the 7-hour expiry problem was explained.
4. **Prefer route definitions and schemas over implementations.** `apiv2/server/apiv2.proto`
   gave the entire API surface in one file. You rarely need the handler bodies.
5. **Verify against the running system.** Every claim in `DESIGN.md` marked *verified* was
   checked with `curl` against tum.live. Source code tells you what *a* version does; the
   live server tells you what *this* deployment does. They differ more often than you'd think.

**Exercise:** pick a claim from `DESIGN.md` and re-derive it yourself without reading my
notes. Good candidate: "gocast detects silence but doesn't expose it." Start from the
worker README's feature list.

---

## Tier 1 — Talking to an API from Flutter

*This is what milestone 1 needs. Highest payoff. Start here.*

### 1.1 Understand the code you already have

Before adding anything, make sure `main.dart` is fully yours. It contains some genuinely
subtle things — if you can explain these three out loud, you're ready:

- **Why does `_pendingSeekSeconds` exist?** (Hint: `seekTo` is async, but the position
  poll fires every 100 ms and may carry a pre-seek value.) See the comment at
  `main.dart` around `_seekSettleWindow`.
- **Why does `_retry()` drop the old controller instead of calling `dispose()`?**
  (Hint: `video_player` only completes `_creatingCompleter` on the success path.)
- **Why do the `ValueListenableBuilder`s exist instead of `setState` on the whole page?**

### 1.2 Dart async

`Future`, `async`/`await`, `.then()`, error handling, and why `if (!mounted) return;`
appears after every `await` in a `State`. You're already using all of this — the goal is
to know *why*, not to discover it.

- Dart docs: "Asynchronous programming: futures, async, await" (do the codelab, ~1 hour)
- Then: `Stream` vs `Future`, because progress updates want a stream.

### 1.3 HTTP and REST

What a request actually is: method, path, query string, headers, status code, body.
You do not need a course — you need to send about twenty requests by hand.

**Exercise A — walk the API with curl.** Run these in order and read every response:

```bash
curl -s https://tum.live/api/v2/status
curl -s https://tum.live/api/v2/semesters | python3 -m json.tool | head -20
curl -s "https://tum.live/api/v2/courses?year=2025&term=W" | python3 -m json.tool | head -40
curl -s "https://tum.live/api/v2/courses/WiSe25VKM?year=2025&term=W" | python3 -m json.tool | head -60
```

Notice: no authentication, and the last one already contains playable video URLs. That
single observation is why `DESIGN.md` says "you probably don't need a backend yet."

**Exercise B — see the auth wall.** 

```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST https://tum.live/api/v2/auth/token   # 401
```

That 401 is the entire reason Tier 3 exists.

Also open <https://tum.live/api/v2/docs> — the Swagger UI for the whole API. You can fire
requests from the browser there.

### 1.4 JSON → Dart objects

Hand-writing `fromJson` is fine and teaches you the most. Learn:

- `dart:convert`, `jsonDecode`, and why it returns `Map<String, dynamic>`
- Writing `factory Course.fromJson(Map<String, dynamic> json)`
- Null safety: the API omits fields (`lastRecording` is optional), so `Stream?` not `Stream`

Later, look at `json_serializable` / `freezed` to generate this. Don't start there —
generate code only once you can write it by hand.

### 1.5 The `http` or `dio` package

Start with `package:http` (simpler). Move to `dio` when you need interceptors, which you
will for the bearer token in Tier 3.

**Milestone-1 exercise:** make the player take `(courseSlug, streamId)`, call
`GET /api/v2/streams/{slug}/{streamId}`, pull `playlistUrl` out of the response, and play
it. Use `WiSe25VKM` / `62189` — it's public, so no login needed. When that works, the
hardcoded-link problem is gone forever.

---

## Tier 2 — How video on the internet actually works

*Needed to understand why the link keeps expiring and how skipping will work.*

### 2.1 HLS

HTTP Live Streaming. The whole idea: instead of one big file, the video is chopped into
~8-second `.ts` segments, and a text file (`.m3u8`) lists them. The player reads the list
and fetches segments as needed. That's why seeking is fast and why streaming works at all.

**Exercise — look inside a real playlist:**

```bash
URL=$(curl -s "https://tum.live/api/v2/streams/WiSe25VKM/62189" \
      | python3 -c "import sys,json;print(json.load(sys.stdin)['stream']['playlistUrl'])")
curl -s "$URL" | head -12
curl -s "$URL" | wc -l      # ~1545 lines for one lecture
```

You'll see `#EXTINF:8.333333,` followed by `segment0000.ts?jwt=...`. Two things to notice:

1. Each segment is 8.3 s. 1545 lines ≈ 770 segments ≈ a 1h45m lecture. The maths works out.
2. **Every segment has its own `?jwt=` appended.** The edge server added those — it
   rewrites the playlist on the fly (`worker/edge/edge.go`, around line 258). The video
   is authorised per segment, not just once.

Learn: master playlist vs media playlist, `#EXT-X-TARGETDURATION`, `#EXT-X-PLAYLIST-TYPE:VOD`
vs live. Apple's HLS overview is the primary source and it's readable.

### 2.2 Why the link dies

**Exercise — decode the token in your own `main.dart`:**

```bash
python3 - <<'PY'
import re, base64, json, datetime
s = open('frontend/tumlive_player/lib/main.dart').read()
tok = re.search(r'jwt=([A-Za-z0-9_\-.]+)', s).group(1)
p = tok.split('.')[1]; p += '=' * (-len(p) % 4)
d = json.loads(base64.urlsafe_b64decode(p))
print(json.dumps(d, indent=2))
print('expires:', datetime.datetime.fromtimestamp(d['exp'], datetime.UTC))
PY
```

You'll see your own `UserID`, the `Playlist` it's bound to, `StreamID`, `CourseID`, and an
`exp` about 7 hours after it was issued. Now you know exactly why hardcoding it fails, and
why `DESIGN.md` insists on storing `(slug, streamId)` instead of a URL.

### 2.3 Codecs vs containers

Enough to not be confused: h264 is a *codec*, `.ts`/`.mp4` are *containers*, HLS is a
*transport*. This matters when you get to ffmpeg, and it's why `-c copy` in the scraper is
fast (repackage, don't re-encode).

---

## Tier 3 — Authentication

*Needed for enrolled courses, i.e. most of the ones you actually want.*

Learn these four ideas in this order. Each one is a concept, not a library:

1. **Cookies.** `Set-Cookie`, `Path`, `Secure`, and especially **`HttpOnly`** — a cookie
   JavaScript cannot read. gocast's session cookie is HttpOnly, which is exactly why the
   login plan in `DESIGN.md` has a fallback.
2. **JWT.** Three base64 parts: header, payload, signature. You already decoded one above.
   Key insight: **the payload is not encrypted, only signed.** Anyone can read it; only the
   holder of the private key could have produced it. gocast signs with RS256, and the edge
   server verifies with the matching public key — which is why no proxy of yours can forge
   a video URL. Play at <https://jwt.io>.
3. **Session vs access token.** gocast has both: a 7-day session cookie, and 15-minute
   bearer tokens minted from it at `POST /api/v2/auth/token`. Understand *why* two: the
   long-lived one is protected by the browser and rarely sent; the short-lived one goes on
   every API call, so it must expire fast if leaked.
4. **SAML / SSO, conceptually.** You never implement SAML — you drive a browser through
   it. All you need: your app sends the user to the identity provider, the IdP
   authenticates them and posts an assertion back to gocast, gocast turns that into a
   session. The app's only job is opening a WebView and noticing when it's over.

Then, Flutter-specific: `webview_flutter` or `flutter_inappwebview`, `flutter_secure_storage`,
and dio interceptors for attaching/refreshing the bearer.

**Do not** learn SAML's XML internals. Genuinely not needed.

---

## Tier 4 — Reading Go and protobuf

*Not to write Go. To verify claims about gocast yourself, including mine.*

You need reading fluency only — about a weekend:

- Structs, methods with receivers (`func (s *Stream) FirstSilenceAsProgress()`), `err`
  returns everywhere, slices, and struct tags like `json:"start"` (that's what decides the
  JSON field name — `model/silence.go` is a 10-line file that shows all of it).
- Skip: goroutines, channels, generics, interfaces-in-depth. Not needed to read handlers.
- A Tour of Go, first three sections, is enough.

**protobuf:** read `apiv2/server/apiv2.proto`. It's the single most useful file in gocast
for you. Learn: `message` = a struct, `service`/`rpc` = an endpoint, field numbers are for
wire compatibility (ignore them), and the `google.api.http` annotation is what maps an RPC
to a REST path. Note the `reserved 15, 16;` in `message Course` — that's how you retire a
field without breaking old clients. Nice thing to have seen once.

**Exercise:** find in the proto which endpoint returns chapter markers, then call it with
curl. Then confirm — by grepping — that silences are *not* in there.

---

## Tier 5 — Backend and ffmpeg

*Only when you start the cut-detection service. Don't pre-learn this.*

- **ffmpeg filters.** Specifically `silencedetect` and `blackdetect`, and the trick that
  they report findings on **stderr** which you parse as text. Run gocast's exact command
  on any video file and read the output. That single exercise demystifies the whole feature.
- **A small web framework.** Go (matches gocast, one binary, ffmpeg-friendly) or FastAPI
  (fastest to write). Either is fine — pick the language you want to practise.
- **Job queues.** Analysis takes minutes; HTTP requests take seconds. You need "accept the
  job, return 202, answer later." Learn the *pattern* before picking a library.
- **Caching + idempotency.** The whole economics of the cut service is "analyse once, serve
  everyone." That's a cache keyed by `streamId`.
- **Docker,** to run ffmpeg reproducibly and to deploy.

---

## What you can safely ignore

Saying this explicitly because the temptation to learn everything is real:

- Kubernetes, microservices, gRPC-as-a-thing-you-write, GraphQL, state-management holy
  wars, Clean Architecture. None of it helps a single-developer lecture player.
- SAML internals, RTMP, video encoding theory, writing your own HLS packager.
- gocast's admin half — course creation, lecture hall management, worker orchestration.
  You are building a *client*. Roughly 70% of that repo is irrelevant to you.

---

## Suggested order

| Week | Focus | Done when |
|---|---|---|
| 1 | Tier 1.1–1.3 | You've run every curl exercise and can explain your own seek code |
| 2 | Tier 1.4–1.5 | Milestone 1 works: player fetches its own URL from `(slug, id)` |
| 3 | Tier 2 | You can explain why the link expires without looking it up |
| 4 | Course browsing UI | Semester → course list → lecture list → player |
| 5–6 | Tier 3 | SSO login works, `/courses/enrolled` returns your real courses |
| 7 | Progress sync | Resume-where-you-left-off via `PATCH /progress/{id}` |
| 8+ | Tier 4, then 5 | You can audit gocast yourself; then build the cut service |

The ordering principle: **each tier is motivated by a feature you're about to build.**
Learning HLS before you've felt the expired-link problem is much less effective than
learning it the day after.

---

## The one habit worth keeping

When something in `DESIGN.md` looks wrong, or a library behaves oddly, or an API returns
something unexpected — **go read the source and probe the live system**, in that order.
gocast is open source; tum.live answers curl. Between those two you can settle almost any
question here without guessing, and without asking anyone.

That's the whole method. Everything else is details.

---

# Update: the prototype exists now

The roadmap above assumed you were building from an empty `lib/`. That changed —
there is a working app. So the learning shifts from *write it* to **read it,
then break it on purpose**, which is faster anyway.

## Read it in this order

Each file builds on the one before. Give yourself an hour per group.

| # | File | What it teaches |
|---|---|---|
| 1 | `lib/src/api/models.dart` | JSON → Dart objects, null safety, defensive parsing |
| 2 | `lib/src/api/tum_live_api.dart` | HTTP, query strings, headers, error mapping |
| 3 | `test/api_test.dart` | How to test a network layer without a network |
| 4 | `lib/src/app_scope.dart` | `InheritedNotifier` — Flutter's built-in DI |
| 5 | `lib/src/auth/auth_controller.dart` | Two-credential auth, caching, single-flight |
| 6 | `lib/src/home/home_page.dart` | `FutureBuilder`, slivers, loading state |
| 7 | `lib/src/player/player_page.dart` | Why URL resolution is its own layer |
| 8 | `lib/src/player/lecture_player.dart` | Controller lifecycle, `didUpdateWidget` |
| 9 | `lib/src/player/player_controls.dart` | The subtle seek/auto-hide logic you already had |

Start every session with `dart run tool/api_smoke.dart`. Seeing the real data
next to the model that parses it is worth more than reading either alone.

## Break it on purpose

The fastest way to prove you understand something is to predict how it fails.
For each of these, **write down what you expect before you run it**:

1. In `models.dart`, change `json['streams']` to `json['lectures']`.
   Which test fails — `api_test.dart` or `app_flow_test.dart`? Why both?
2. In `auth_controller.dart`, delete the `_pendingMint` guard.
   Which test catches it? What would the symptom be in the real app?
3. In `player_page.dart`, cache the `playlistUrl` in a field instead of
   re-fetching. Nothing fails today. When would it, and why did that bug make
   the original hardcoded link useless?
4. In `tum_live_api.dart`, remove the `Authorization` header.
   Which screens still work? That answer is the whole public/enrolled split.

## Then extend it

In rough order of difficulty. Each is genuinely missing:

| Feature | Where it goes | Hint |
|---|---|---|
| Chapter markers | `player_page.dart` | `api.getSections()` already exists and is unused. Draw ticks on the seek bar. |
| Bookmarks | new `bookmarks/` | The API has `GET/POST/PUT/DELETE /bookmarks`. Add them to `TumLiveApi` first. |
| Subtitles | `player_page.dart` | `/streams/{slug}/{id}/subtitles/{lang}` returns WebVTT. |
| Search | `home_page.dart` | Not in API v2 — filter the loaded list client-side for now. |
| Pin / unpin | `course_page.dart` | `api.setCoursePinned()` exists and nothing calls it. |
| Real SSO login | `auth/` | `flutter_inappwebview`, then `signInWithSessionCookie`. Mobile first. |
| Secure storage | `credential_store.dart` | One new class implementing the existing interface. |
| Cut detection | a new backend | The big one. See `backend/DESIGN.md`. |

The first two are the best starting points: `getSections` and `setCoursePinned`
are already written and tested, so you are only writing UI — and you get to see
your change on screen in a minute.

## What changed about the tiers

- **Tier 1 (Dart async, HTTP, JSON)** — no longer something to learn before
  writing code. Read groups 1–3 above instead; the code is the tutorial.
- **Tier 2 (HLS)** — unchanged, still worth doing, and now you can point at
  `player_page.dart` and see why it matters.
- **Tier 3 (auth)** — read `auth_controller.dart`'s doc comment first. It
  explains the two-credential design better than an article would, because it
  is about this exact server.
- **Tier 4 (Go/protobuf)** — bumped up in value. Every field name in
  `models.dart` came from `apiv2.proto`. When a field looks wrong, that file is
  the source of truth.
- **Tier 5 (backend/ffmpeg)** — unchanged, still the last step.
