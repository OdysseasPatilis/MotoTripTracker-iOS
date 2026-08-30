# R&D: MotoTripTracker Backend

Study notes for a self-hosted backend that supports **live buddy share**, **cloud ride sync**, **leaderboards**, and later **light social**. Not a build plan to implement today — a map of options, costs, and a sensible order of work.

Last updated: 2026-08-30  
Context: iOS app is local-first (SwiftData). Backend is net-new.

---

## 1. What problem the backend solves

Today the app is strong **on-device**: tracking, limits, nav, moments, personal leaderboard, GPX/share.

A backend unlocks features that **cannot** stay only on one phone:

| Capability | Needs server? | Why |
| --- | --- | --- |
| Group / buddy live location | Yes | Viewers (web or other phones) need a shared ephemeral session |
| Sync rides across devices | Yes *or* CloudKit | Cross-device / backup beyond one Apple ID story |
| Global / friends leaderboards | Yes | Aggregate scores across users |
| Share ride pages / links that outlive the phone | Yes | Public or semi-public URLs |
| Messaging | Yes | Delivery, history, push |
| Crash / emergency SMS | Mostly device + carrier APIs | Backend optional for logging / contacts sync |

**Product north star for v1:** temporary, ride-aware presence — not a social network.

> Live share = “where is Odysseas on this ride, for the next few hours?”  
> Not = followers, feed, permanent public profile.

---

## 2. Product: Group / buddy live share (core of Phase 1)

### Jobs to be done
- **Convoy:** friends see each other without WhatsApp spam  
- **Solo safety:** partner sees you’re still moving / roughly on route  
- **Meetup:** “I’m ~8 min out” without calls while riding  

### Premium feel
1. One tap **Share ride** → link / Messages / WhatsApp  
2. Viewer opens a **simple map** (web v1; in-app later)  
3. You control **who**, **precision**, **duration**  
4. Auto-ends on stop ride or TTL (e.g. 4–12 h); always **revocable**

### Privacy model (non-negotiable)
- Opt-in per ride (off by default)  
- Short-lived, non-indexable links  
- Optional PIN  
- Coarse mode (~100–200 m blur) until “nearby”  
- Don’t expose speed / over-limit / home history for v1  
- Viewer **no account** for v1 (magic link)  
- Copy: convenience tool, **not** emergency monitoring  

### Product phases (live share alone)
1. **Solo share link** — one rider → many viewers (highest value / lowest complexity)  
2. Mute/pause sharing without ending the ride  
3. **Convoy code** — multi-rider session, leader/member  
4. **App-to-app** — buddy Live Activity / in-app dots  

---

## 3. DIY vs BaaS vs Apple-only

| Approach | Pros | Cons | Fit |
| --- | --- | --- | --- |
| **DIY API** (recommended long-term) | Full control; global boards; web viewers; ownership | You own ops, auth, GDPR | Best if you want leaderboards + live + share pages |
| **Firebase / Supabase** | Fast to ship; auth + realtime | Vendor lock-in; costs spike with live writes; less “yours” | Good for prototype |
| **CloudKit only** | Cheap; Apple-native sync | Awkward for Android/web viewers; weak for public links | Fine for *your* multi-device sync, bad for buddy web map |
| **WhatsApp / Find My** | Users already have it | Not embeddable as your product | Competitor for “just location,” not for ride-aware UX |

**Recommendation:** thin custom API. Use CloudKit later *only* if you want Apple-only backup as a parallel path — pick **one primary sync story** for rides metadata.

---

## 4. Suggested stack (solo / small team)

Keep it boring and cheap.

```
┌─────────────┐     HTTPS / WSS      ┌──────────────────┐
│ iOS app     │ ───────────────────► │ API (Vapor /     │
│ (+ web map) │ ◄─────────────────── │  Node / Go)      │
└─────────────┘                      └────────┬─────────┘
                                              │
                         ┌────────────────────┼────────────────────┐
                         ▼                    ▼                    ▼
                   Postgres              Redis (TTL)           Object store
                   users, rides,         live session         (later: media)
                   boards, sessions      lat/lon dots
                   metadata
```

| Layer | Choice | Notes |
| --- | --- | --- |
| API | **Swift Vapor**, Node (Fastify/Hono), or Go | Pick whatever you’re fastest in. Vapor keeps one language with iOS. |
| DB | **Postgres** | Users, finished rides, leaderboard rows, share session metadata |
| Live state | **Redis** (or in-memory + TTL on one box early) | `sessionId → {lat, lon, updatedAt, …}` — **do not** write GPS every second to Postgres |
| Auth | **Sign in with Apple** | Required for App Store social features; optional Google later |
| Push | APNs via your API | Free protocol; your server still needs to store device tokens |
| Host | Fly.io, Railway, Render, or **Hetzner/DO VPS** | No Kubernetes at the start |
| Viewer | Static web map (MapLibre / MapKit JS / Leaflet) | Poll or SSE/WebSocket |

---

## 5. Architecture principles

1. **Local-first ride recording stays on device** — GPS pipeline in `TripManager` unchanged. Backend is an *upload* of summaries / live points, not a rewrite of tracking.  
2. **Ephemeral vs durable** — live dots die with TTL; finished rides are durable (if user opts into cloud).  
3. **Throttle uploads** — every **5–15 s** while moving; slower when stopped; never 1 Hz to the server.  
4. **Small payloads** — `{ lat, lon, course, speed?, destination?, battery?, ts }` plus session secret.  
5. **No full trail required for v1** — optional short breadcrumb only. Full polyline uploads belong to “finished ride sync.”  
6. **Separate chat** — don’t couple messaging tables to live location paths.  
7. **Anti-abuse early** — rate limits, expire/revoke, no crawlable URLs, later anti-cheat for boards.

---

## 6. Data model sketch

### Durable (Postgres)

```text
users
  id, apple_sub, display_name, created_at, deleted_at

devices
  id, user_id, apns_token, platform, updated_at

rides (cloud copy — Phase 2)
  id, user_id, started_at, ended_at
  distance_m, moving_s, max_speed, twistiness, corner_count
  polyline (encoded), moments_json?, visibility (private|friends|public)

leaderboard_period (Phase 3)
  id, period (week|month|all), metric, scope (global|club)
  entries materialized or computed from rides

share_sessions (metadata only)
  id, owner_user_id, token_hash, pin_hash?
  precision (exact|coarse), show_destination bool
  expires_at, revoked_at, ended_at
  mode (solo_link|convoy)

convoy_members (Phase 5)
  session_id, user_id, role (leader|member), joined_at
```

### Ephemeral (Redis)

```text
live:{session_id} → JSON {
  lat, lon, course, speed?, destination?, battery?,
  updated_at, owner_display?
}
TTL = remaining share lifetime (refresh on each upload)

viewers:{session_id} → approx viewer count (optional, INCR with short TTL)
```

---

## 7. API sketch (v1 live share)

Auth: Sign in with Apple → API issues JWT (or session cookie for web admin later).

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/v1/auth/apple` | Exchange Apple identity token → app JWT |
| `POST` | `/v1/share/sessions` | Start share (duration, precision, PIN?) → `{ sessionId, viewUrl, shareToken }` |
| `POST` | `/v1/share/sessions/:id/location` | Authenticated uploader posts GPS sample |
| `POST` | `/v1/share/sessions/:id/end` | End / revoke |
| `POST` | `/v1/share/sessions/:id/pause` | Mute without ending ride |
| `GET` | `/v1/share/view/:token` | Public viewer: last fix + age (+ optional PIN header) |
| `GET` | `/v1/share/view/:token/stream` | SSE or WebSocket push of updates |

**Later**

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/v1/rides` | Upload finished ride summary + encoded polyline |
| `GET` | `/v1/rides` | List my cloud rides |
| `DELETE` | `/v1/account` | GDPR delete |
| `GET` | `/v1/leaderboards/:metric` | Friends / global week |
| `POST` | `/v1/convoy` | Create / join code |

### Client integration points (iOS)
- Hook share start/stop next to ride lifecycle (`TripManager` / dashboard Share sheet)  
- Background-safe location uploader with adaptive interval  
- Chip: **Sharing · N viewers · Stop**  
- Live Activity: optional “Sharing on”  
- Deep link: `mototriptracker://share/...` for app-installed viewers later  

---

## 8. Phased roadmap (cost + complexity)

### Phase 1 — Live share only (backend v0)
- Apple auth (uploader)  
- Create / pause / end session  
- Location upload + Redis TTL  
- Public view link (web map), optional PIN  
- Auto-expire + revoke  

**Ship this first.** Highest rider utility per engineering hour.

### Phase 2 — Account cloud + ride sync
- Upload finished rides (stats + polyline, not raw 1 Hz forever)  
- Decide: **your server** vs CloudKit as primary  
- Account delete / export  

### Phase 3 — Leaderboards
- Start **friends / club**, then global  
- Metrics: weekly distance, twistiness, corners, max speed  
- Materialize weekly tables; don’t `ORDER BY` huge raw tables every request  
- Anti-cheat later (teleport, impossible speeds — you already reject >80 m jumps on device; mirror server-side sanity checks)

### Phase 4 — Social surface
- Public / friends ride pages (share cards already exist as images)  
- Light messaging: ride invite, “I’m here” — **not** full WhatsApp clone  

### Phase 5 — Convoy live map
- Session codes, multi-dots, roles  
- In-app buddy map + Live Activity for installed buddies  

**Delay full chat** until people already open the app for live share / rides. Generic chat loses to WhatsApp; your edge is **ride-aware** presence.

---

## 9. Hosting cost (order of magnitude)

| Scale | Rough monthly | What you run |
| --- | --- | --- |
| You + friends / few dozen | **~€0–20** | Free tier or one small VPS (e.g. Hetzner CX22-class) + managed Postgres optional |
| Hundreds of active riders | **~€20–80** | Always-on API + Redis + Postgres backups |
| Thousands + live + chat + media | **€100+** | Bandwidth, DB size, push infra, CDN, moderation |

### What burns money
- Live GPS at high frequency / many open WebSockets  
- Media (photos/videos) storage + CDN  
- Naive global leaderboard queries  
- Abuse / moderation tooling  

### What stays cheap
- 5–15 s updates  
- Redis TTL, drop on end  
- Stats-only ride uploads  
- APNs (protocol free; your box is the cost)

**Early target:** one small VM or Fly machine ≈ “a coffee a month” until real usage.

---

## 10. Privacy, legal, liability (budget time)

You are in the EU (Greece) — plan GDPR from Phase 1 accounts onward:

- Privacy policy + terms  
- **Delete account** and data export  
- Lawful basis / consent for location sharing  
- Retention: live data gone after TTL; rides retained per user settings  
- Clear disclaimer: **not an emergency / not a medical or rescue service**  
- Stalking mitigations: short TTL, revoke, PIN, no SEO, rate-limit view tokens  

Crash detection + SMS to emergency contacts is a **separate** feature with its own legal/UX care.

---

## 11. Alternatives & traps

| Trap | Better path |
| --- | --- |
| Writing every GPS point to Postgres | Redis/memory + TTL; Postgres for session metadata only |
| Building chat + boards + convoy on day one | Live share link → cloud rides → friends board |
| Relying on CloudKit for web buddy viewers | Custom view URL |
| 1 Hz server uploads | 5–15 s adaptive |
| Global boards without anti-cheat | Friends-first boards |
| “Emergency monitoring” marketing | Convenience / convoy wording only |

---

## 12. Study checklist (how to learn this stack)

Use this as a self-study path before writing production code.

### Concepts
- [ ] REST vs SSE vs WebSocket for live maps  
- [ ] JWT after Sign in with Apple (token verify with Apple’s keys)  
- [ ] Redis keys + TTL patterns  
- [ ] Postgres migrations / basic indexing  
- [ ] Rate limiting and token hashing (store hash of view token, not raw)  
- [ ] Background URLSession uploads on iOS while riding  

### Hands-on mini projects
1. Hello API on Fly/Hetzner: `GET /health`  
2. Redis `SET live:demo … EX 300` + `GET` from a tiny web page  
3. Static Leaflet/MapLibre page that polls every 5 s  
4. iOS prototype: post location every 10 s with a hard-coded session secret  
5. Add Apple Sign In + revoke endpoint  
6. Only then: Postgres users + finished ride upload  

### Reading / docs to skim
- [Sign in with Apple – REST verification](https://developer.apple.com/documentation/sign_in_with_apple/sign_in_with_apple_rest_api)  
- Redis TTL / ephemeral session patterns  
- Your chosen host: Fly.io or Hetzner + Caddy/nginx TLS  
- GDPR “right to erasure” checklist for accounts + location  

### Open questions to decide before coding
1. Primary language for API: Vapor vs Node vs Go?  
2. Web map library (cost of MapKit JS vs MapLibre + tiles)?  
3. Cloud ride sync: custom server only, or CloudKit for Apple devices + server for social?  
4. Free tier forever vs paid “Convoy / Premium” entitlement?  

---

## 13. Concrete “next sketch” (when you want to go deeper)

When ready to leave R&D and design v1 for real, flesh out:

1. Exact OpenAPI for Phase 1 endpoints  
2. Fly.io **or** Hetzner monthly line-item estimate (CPU, volume, egress)  
3. Web viewer wireframe (one screen)  
4. iOS Share sheet fields (duration, precision, destination on/off)  
5. Threat model: leaked link, stalker, forged scores  

---

## 14. Bottom line

- **Yes, you can build the backend yourself.**  
- **Early hosting need not be expensive** (~€0–20/mo) if live state is Redis+TTL and uploads are throttled.  
- Treat “leaderboards + chat + live buddies” as a **platform**, shipped in phases.  
- **Phase 1 = revocable, expiring live map link tied to an active ride.** That is the premium, moto-useful version of buddy share — and the right first backend.

---

## Related app surfaces (today)

Local features that will *feed* or *complement* the backend later:

- Live GPS / `TripManager` → location uploader  
- Nav destination / ETA → optional viewer fields  
- Live Activity → “Sharing on”  
- Personal leaderboard / twistiness → cloud & friends boards  
- Existing post-ride image + GPX share → different from *live* share  

This document does not change the iOS app; it is study material only.
