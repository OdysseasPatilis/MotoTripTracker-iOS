# Traffic Camera Alerts

**Date:** 2026-09-08  
**Status:** Approved for implementation planning  
**App:** MotoTripTracker iOS  

## Goal

While a ride is being recorded, warn the rider that a **speed camera** or **red-light camera** is ahead (voice + haptic + short HUD banner), and show nearby cameras as icons on the live map.

## Decisions (approved)

| Topic | Choice |
| --- | --- |
| Camera kinds | Speed + red-light only (not average-speed / section control) |
| When active | Whenever a ride is recording (active, not paused); with or without navigation |
| Alert UX | Voice + haptic + HUD banner + map icons |
| Warn distance | Speed-based (farther at higher speed) |
| Data strategy | Bundled Athens pack + live Overpass fill-in + small disk cache |

## Out of scope (v1)

- Average-speed / section-control cameras
- Dedicated mute toggle (reuse navigation voice mute / `NavigationVoicePrompt.isEnabled`)
- Alerts when idle or ride paused
- Non-Athens offline packs (Overpass + cache cover elsewhere)
- Editing / reporting camera locations

## Current baseline

- GPS fan-out in `AppContainer` already refreshes `SpeedLimitService` while riding.
- Overpass mirrors and HTTP style exist in `SpeedLimitService` / petrol finder.
- Bundled region pack pattern exists (`athens_speed_limits.json` + `Scripts/build_athens_speed_limit_pack.py`).
- Turn voice uses `NavigationVoicePrompt`; HUD banners exist in `RideTrackerView` (e.g. timing result).
- Live map annotations live in `LiveRideMapView`.

## Design

### Domain model

```swift
enum TrafficCameraKind: String, Codable, Sendable {
    case speed
    case redLight
}

struct TrafficCamera: Identifiable, Hashable, Sendable {
    let id: String          // stable: "osm:\(type)/\(id)" or pack id
    let latitude: Double
    let longitude: Double
    let kind: TrafficCameraKind
}

struct TrafficCameraAlert: Equatable, Sendable {
    let camera: TrafficCamera
    let distanceMeters: CLLocationDistance
}
```

Spoken / banner copy:

- Speed → “Speed camera ahead” / banner “Speed camera · {distance}”
- Red light → “Red light camera ahead” / banner “Red light camera · {distance}”

### Bundled pack format

File: `MotoTripTracker/Resources/athens_traffic_cameras.json`

```json
{
  "id": "athens_traffic_cameras",
  "name": "Greater Athens traffic cameras",
  "version": 1,
  "south": 37.82,
  "west": 23.55,
  "north": 38.15,
  "east": 23.95,
  "cameras": [
    {
      "id": "osm:node/123",
      "lat": 37.97,
      "lon": 23.72,
      "kind": "speed"
    }
  ]
}
```

Same Greater Athens bbox as the speed-limit pack. Cameras are a **point list**, not a grid (cameras are sparse).

Builder: `Scripts/build_athens_traffic_cameras_pack.py` — Overpass query for the bbox, write the JSON. Document rebuild next to the speed-limit pack in README.

### OSM query (pack + live)

Include:

- `node/way["highway"="speed_camera"]`
- `node/way["enforcement"="maxspeed"]`
- `node/way["enforcement"="traffic_signals"]`

Map to kinds:

- `highway=speed_camera` or `enforcement=maxspeed` → `.speed`
- `enforcement=traffic_signals` → `.redLight`

Ways: use centroid / first node coordinate from Overpass `out center` (or equivalent) so every result has a point.

### `TrafficCameraService`

`@Observable` `@MainActor`, owned by `AppContainer`.

**State**

- `nearbyCameras: [TrafficCamera]` — map annotations (within ~1.5 km of rider)
- `activeAlert: TrafficCameraAlert?` — drives HUD banner
- Private: pack cameras, disk cache, last Overpass fetch location/time, announced camera IDs / approach cooldowns

**Lifecycle**

- Init: load bundled pack + disk cache
- `refresh(for: CLLocation)` — called from `AppContainer` GPS path when `session.isActive && !session.isPaused`
- `reset()` — clear alert / approach state when trip ends (keep pack + cache)

**Refresh pipeline**

1. Build candidate set from pack (if location in bbox) ∪ disk cache ∪ recent Overpass results.
2. If outside pack, or moved ≥ ~400 m / waited ≥ ~45 s since last Overpass, fetch live around rider (~1–1.5 km radius) using the same Overpass mirrors / User-Agent style as speed limits.
3. Merge by `id`; persist merged remote results to disk cache (bounded size / TTL, e.g. keep last few thousand or drop entries older than ~30 days).
4. Publish `nearbyCameras` filtered to ~1.5 km.
5. Evaluate alerts (below).

**Warn distance**

```text
distance = clamp(speed_mps × 8 seconds, 250 m, 700 m)
```

If `speed < 0` or very low (GPS uncertain), use the 250 m floor.

**Heading / ahead filter**

- Compute bearing from rider to camera.
- Require absolute heading difference ≤ ~45°, **or** treat as ahead when speed is below ~3 m/s (urban crawl / stop).
- Skip cameras clearly behind the rider.

**Announce once per approach**

- When a camera first enters the warn cone: set `activeAlert`, speak, light haptic.
- Do not re-announce the same `id` until the rider has moved away (e.g. distance > warn distance + 80 m) or trip resets.
- Banner auto-clears after ~5–6 s or when `activeAlert` is cleared; voice respects `NavigationVoicePrompt.isEnabled`.

**Shared voice**

Inject or share the same `NavigationVoicePrompt` instance used by navigation (or a thin wrapper that reads the same `moto_nav_voice_enabled` key) so mute applies to camera prompts.

### UI

**`LiveRideMapView`**

- While ride active: `ForEach(nearbyCameras)` annotations.
- Distinct SF Symbol / tint for speed vs red-light (readable at glance, not large cards).

**`RideTrackerView`**

- Observe `activeAlert`; show a short banner (same visual family as timing banner) with kind + distance.
- Auto-dismiss when alert clears or after timeout.

No new settings screen in v1.

### Wiring

`AppContainer`:

- Construct `TrafficCameraService`.
- On location update: if ride active and not paused → `trafficCameraService.refresh(for: location)`.
- On trip end / discard → `trafficCameraService.reset()`.

### Testing

Unit / logic tests:

- Warn-distance clamp at low / mid / high speed
- Heading filter: ahead vs behind
- Pack JSON decode
- Overpass element → `TrafficCameraKind` mapping

Manual:

- Start a ride in Athens with pack present; confirm map icons appear near known OSM cameras
- Confirm voice + banner fire once when approaching
- Mute nav voice → no spoken camera alert (haptic/banner still OK)
- Pause ride → no new alerts

### Files to add / touch

| Path | Role |
| --- | --- |
| `Domain/TrafficCamera.swift` (or under Services) | Models |
| `Services/TrafficCameraService.swift` | Pack + Overpass + alerts |
| `Services/TrafficCameraRegionPack.swift` | Pack load/decode (optional split) |
| `Resources/athens_traffic_cameras.json` | Bundled pack |
| `Scripts/build_athens_traffic_cameras_pack.py` | Pack builder |
| `AppContainer.swift` | Wire refresh/reset |
| `UI/Tracker/LiveRideMapView.swift` | Annotations |
| `UI/Tracker/RideTrackerView.swift` | Alert banner |
| `MotoTripTrackerTests/...` | Logic tests |
| `README.md` | Feature + rebuild note |

## Error handling

- Overpass failure: keep pack + cache; log warning; do not clear existing `nearbyCameras` aggressively on a single failure.
- Missing pack resource: log error; live Overpass + cache still work.
- Invalid pack entry: skip that camera; load the rest.

## Success criteria

1. During an active ride, approaching a known speed or red-light camera yields one voice prompt, haptic, and short banner.
2. Map shows nearby camera icons while riding.
3. Offline inside Greater Athens still shows pack cameras and can alert from pack data alone.
4. Outside Athens (online), Overpass fill-in still provides alerts.
5. Paused / idle: no camera alerts.
