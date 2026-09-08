# Traffic Camera Alerts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Warn riders of speed and red-light cameras ahead during active rides, with map icons, using an Athens pack plus Overpass fill-in.

**Architecture:** Pure `TrafficCamera` domain helpers for warn distance / heading / OSM kind mapping; `TrafficCameraRegionPack` loads bundled JSON; `TrafficCameraService` merges pack + cache + Overpass, publishes `nearbyCameras` / `activeAlert`; `AppContainer` refreshes while riding; map + HUD consume that state. Voice uses `NavigationVoicePrompt` (same mute key as nav).

**Tech Stack:** SwiftUI, CoreLocation, Overpass HTTP, bundled JSON, AVSpeech via existing `NavigationVoicePrompt`.

## Global Constraints

- Camera kinds: speed + redLight only
- Active only when ride recording and not paused
- Warn distance: `clamp(speed_mps × 8, 250…700)` m
- Ahead filter: ±45° heading, or treat as ahead if speed &lt; 3 m/s
- Pack bbox: Greater Athens 37.82–38.15 N, 23.55–23.95 E
- No dedicated mute UI (reuse nav voice enabled flag)

---

### Task 1: Domain models + pure logic (TDD)

**Files:**
- Create: `MotoTripTracker/Domain/TrafficCamera.swift`
- Modify: `MotoTripTrackerTests/MotoTripTrackerTests.swift`

- [ ] Write failing tests: warn-distance clamp; ahead vs behind; OSM tag → kind
- [ ] Implement models + `TrafficCameraLogic` helpers until green

### Task 2: Pack decode + builder script

**Files:**
- Create: `MotoTripTracker/Services/TrafficCameraRegionPack.swift`
- Create: `Scripts/build_athens_traffic_cameras_pack.py`
- Create: `MotoTripTracker/Resources/athens_traffic_cameras.json` (run builder or seed minimal)

- [ ] Test pack JSON decode
- [ ] Implement pack loader mirroring speed-limit resource lookup
- [ ] Add Python builder; generate Athens pack from Overpass

### Task 3: `TrafficCameraService`

**Files:**
- Create: `MotoTripTracker/Services/TrafficCameraService.swift`
- Modify: `MotoTripTracker/Utilities/AppLogger.swift` (optional `trafficCamera` category)

- [ ] Service: load pack/cache, throttle Overpass, merge, nearby filter, alert + voice/haptic
- [ ] `reset()` clears alert/approach state

### Task 4: Wire + UI + docs

**Files:**
- Modify: `AppContainer.swift`, `LiveRideMapView.swift`, `RideTrackerView.swift`, `README.md`

- [ ] Refresh while active; reset on stop
- [ ] Map annotations; alert banner
- [ ] README feature + rebuild command
