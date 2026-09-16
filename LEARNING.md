# Learning your way around this codebase

Written for the person maintaining this app. `README.md` says what everything
*is*; this says how to build a working understanding of it, and what to try next.

## How to read a codebase you didn't write

This is the method that produced `DESIGN.md`, and it's the most transferable
thing here.

1. **Read the README first**, especially any architecture diagram. gocast's has
   an ASCII one showing Website / Worker / Edge / VoD-Service / CAMPUSOnline.
   Five minutes there saves an hour of guessing.
2. **List directories before opening files.** `worker/`, `edge/`, `apiv2/` told
   me the shape of the system before I read a line of Go.
3. **Follow the noun you care about.** "Where does the video URL come from?" →
   grep `playlist` → `SetSignedPlaylists` → one function, and the 7-hour expiry
   problem was explained.
4. **Prefer schemas over implementations.** `apiv2/server/apiv2.proto` gives the
   entire API surface in one file. You rarely need the handler bodies.
5. **Verify against the running system.** Source tells you what *a* version does;
   `curl` tells you what *this deployment* does. They differ more often than
   you'd think.

---

## Read this code in this order

Each builds on the one before. Roughly an hour per group.

| # | File | What it teaches |
|---|---|---|
| 1 | `lib/src/api/models.dart` | JSON → Dart objects, null safety, defensive parsing |
| 2 | `lib/src/api/tum_live_api.dart` | HTTP, query strings, headers, error mapping |
| 3 | `test/api_test.dart` | Testing a network layer without a network |
| 4 | `lib/src/app_scope.dart` | `InheritedNotifier` — Flutter's built-in DI |
| 5 | `lib/src/auth/token_source.dart` | Why the session and the token are separate |
| 6 | `lib/src/auth/auth_controller.dart` | Caching, refresh margin, single-flight |
| 7 | `lib/src/home/home_page.dart` | `FutureBuilder`, slivers, loading state |
| 8 | `lib/src/player/player_page.dart` | Why URL resolution is its own layer |
| 9 | `lib/src/player/player_controls.dart` | The subtle seek and auto-hide logic |

Start any session with `dart run tool/api_smoke.dart`. Seeing real data next to
the model that parses it is worth more than reading either alone.

---

## Poke the real API

Twenty requests by hand teach more than a course. Read every response:

```bash
curl -s https://tum.live/api/v2/status
curl -s https://tum.live/api/v2/semesters | python3 -m json.tool | head -20
curl -s "https://tum.live/api/v2/courses?year=2025&term=W" | python3 -m json.tool | head -40
curl -s "https://tum.live/api/v2/courses/WiSe25VKM?year=2025&term=W" | python3 -m json.tool | head -60
```

No authentication, and the last one already contains playable video URLs. That
single observation is why this app has no backend.

Then the auth wall:

```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST https://tum.live/api/v2/auth/token   # 401
```

Swagger for everything else: <https://tum.live/api/v2/docs>.

### See why a playlist URL expires

```bash
# export, not just assign: the Python below reads it from the environment
export URL=$(curl -s "https://tum.live/api/v2/streams/WiSe25VKM/62189" \
      | python3 -c "import sys,json;print(json.load(sys.stdin)['stream']['playlistUrl'])")

# The playlist: ~8s segments, each with its own ?jwt= added by the edge server
curl -s "$URL" | head -12

# The token itself — signed, not encrypted, so anyone can read the payload
python3 - <<'PY'
import os, re, base64, json, datetime
tok = re.search(r'jwt=([A-Za-z0-9_\-.]+)', os.environ['URL']).group(1)
p = tok.split('.')[1]; p += '=' * (-len(p) % 4)
d = json.loads(base64.urlsafe_b64decode(p))
print(json.dumps(d, indent=2))
print('expires:', datetime.datetime.fromtimestamp(d['exp'], datetime.UTC))
PY
```

You'll see the claims in plaintext and an `exp` about 7 hours out. Two lessons in
one command: **a JWT is signed, not secret**, and this URL cannot be cached.

---

## Break it on purpose

The fastest way to prove you understand something is to predict how it fails.
**Write down what you expect before running each one.**

1. In `models.dart`, change `json['streams']` to `json['lectures']`.
   Which test fails — `api_test.dart` or `app_flow_test.dart`? Why both?
2. In `auth_controller.dart`, delete the `_pendingMint` guard.
   Which test catches it? What would the symptom be in the real app?
3. In `player_page.dart`, cache the URL in a field instead of re-resolving.
   Nothing fails today. When would it, and why?
4. In `tum_live_api.dart`, remove the `Authorization` header.
   Which screens still work? That answer is the whole public/enrolled split.

---

## Then extend it

Roughly by difficulty. Each is genuinely missing.

| Feature | Where | Hint |
|---|---|---|
| Pin / unpin | `course_page.dart` | `api.setCoursePinned()` is written and tested; nothing calls it |
| Chapter markers | `player_page.dart` | `api.getSections()` exists and is unused. Draw ticks on the seek bar |
| Bookmarks | new `bookmarks/` | `GET/POST/PUT/DELETE /bookmarks`. Add to `TumLiveApi` first |
| Subtitles | `player_page.dart` | `/streams/{slug}/{id}/subtitles/{lang}` returns WebVTT |
| Search | `home_page.dart` | Not in API v2 — filter the loaded list client-side |
| Secure storage | `credential_store.dart` | One new class implementing the existing interface |
| Cut detection | a new backend | The big one. See `DESIGN.md` |

The first two are the best starting points: the API calls are already written and
tested, so you're only writing UI and you see it on screen in a minute.

---

## What you can safely ignore

The urge to learn everything is real, so: Kubernetes, microservices, GraphQL,
Clean Architecture, state-management debates, SAML's XML internals, RTMP, video
encoding theory. Also gocast's entire admin half — course creation, lecture hall
management, worker orchestration. **You are building a client; most of that repo
is irrelevant to you.**

## The one habit worth keeping

When something looks wrong — in these docs, in a library, in an API response —
read the source and probe the live system, in that order. gocast is open source
and tum.live answers `curl`. Between those two you can settle almost any question
in this project yourself, without guessing and without asking anyone.
