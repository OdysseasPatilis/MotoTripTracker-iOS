# Riding Camera Look-Ahead, Turn Zoom & Larger Turn HUD

**Date:** 2026-09-13  
**Status:** Approved for implementation planning  
**App:** MotoTripTracker iOS  

## Goal

While recording a ride (and especially while navigating), make the live map feel more like motorcycle navigation: **more road ahead on screen**, **closer zoom when a turn is approaching**, and a **larger, glanceable turn banner**.

## Decisions (approved)

| Topic | Choice |
| --- | --- |
| Approach | Camera math in `LiveRideMapView` + enlarge existing `topTurnBanner` (no new camera service) |
| Look-ahead | Speed-scaled: mild when slow, stronger when fast / navigating |
| Turn zoom | Speed-scaled approach window (farther at high speed, closer in city) |
| Turn HUD | Bigger banner: larger icon, larger distance, 2-line instruction, more padding |
| When camera policy applies | Active recording follow (`isRiding` + `isFollowingUser`); not idle top-down explore |

## Out of scope (v1)

- Polyline / road-geometry look-ahead
- Separate nav-camera service or mode enum beyond local helpers
- Redesigning bottom chrome, petrol button, or preview card
- Changing spoken prompt distances (voice stays as today; zoom window is independent but aligned at mid speed ~250 m)

## Current baseline

- `LiveRideMapView.updateCamera`: when riding, centers on GPS with pitch 55° and distance `350 + min(speedKmh, 180) * 7`; when idle, top-down distance 1400, heading 0
- Follow pauses on user pan; Recenter restores follow
- Preview phase uses `fitPreviewRoute` and does not run follow camera
- `RideTrackerView.topTurnBanner`: 44pt icon, `.title3` distance, `.caption` instruction with `lineLimit(1)`
- `NavigationService.distanceToNextManeuver` and `currentStep` already drive the banner and voice

## Design

### 1. Look-ahead (rider lower on screen)

While riding and following:

1. Compute a **forward offset** along `location.course` (degrees → meters ahead of the rider).
2. Use that offset coordinate as `MapCamera.centerCoordinate` so the rider sits in the **lower portion** of the viewport and more road is ahead.
3. Scale offset with speed (and bump slightly when navigation has an active route / guiding):

| Context | Approx rider placement | Intent |
| --- | --- | --- |
| Slow (~20 km/h) | Lower third | Mild forward bias |
| Fast (~100+ km/h) | Near bottom | Strong look-ahead |
| Navigating | Same curve + small extra | Prefer road ahead while following a route |

4. Keep pitch ~**55°**. Keep the existing **cruise distance** curve as the baseline (before turn zoom).
5. If `course < 0` (no heading yet), center on the rider with no offset until course is valid.

Implementation note: offset can be a simple destination projection from the rider coordinate (haversine / `MKMapPoint` meter offset along heading). No MapKit camera padding API required.

### 2. Turn approach zoom

Only when navigation is actively guiding (has a current step / maneuver distance) and follow is on:

1. Define an **approach start distance** that scales with speed, e.g.:
   - ~40 km/h → start ~120–150 m  
   - ~80 km/h → start ~250 m (aligned with spoken approach)  
   - ~120+ km/h → start ~350–400 m  
2. When `distanceToNextManeuver` ≤ start distance, **reduce** camera `distance` toward a closer floor (junction fills more of the screen). Blend by how deep into the window you are (linear or ease).
3. Closest zoom is still usable on a bike — not street-level extreme; cruise distance remains the outer bound.
4. When the step advances or distance leaves the window, ease back to cruise distance using the existing ~**0.45s** camera animation.
5. Arrival / last step: allow approach zoom; after navigation finishes, resume normal riding camera (or idle if recording stopped).

No change to off-route / recalculating camera beyond continuing look-ahead with cruise distance (skip aggressive junction zoom while recalculating if step distance is unreliable).

### 3. Larger turn banner

Update `topTurnBanner` in `RideTrackerView` only:

| Element | Current | Target |
| --- | --- | --- |
| Maneuver icon frame | 44×44 | ~56×56 |
| Icon font | `.title2` | slightly larger (e.g. `.title`) |
| Distance | `.title3` bold | `.title` bold |
| Instruction | `.caption`, 1 line | `.subheadline` semibold, **2 lines** |
| Padding | 12 / 8 | modestly increased |

Recalculating / off-route / calculating states use the same larger typography so the banner does not shrink in those modes.

### 4. Touch points

| File | Change |
| --- | --- |
| `LiveRideMapView.swift` | Look-ahead center + turn-zoom distance in `updateCamera`; small private helpers / constants |
| `RideTrackerView.swift` | Enlarge `topTurnBanner` |
| Optional | Tiny shared constants file only if duplication appears; prefer locals first |

### 5. Edge cases

- User pans → follow off → camera policy paused; Recenter clears selection and restores riding camera with look-ahead / zoom as applicable.
- Route preview → unchanged `fitPreviewRoute`; clear place card behavior unchanged.
- No navigation → look-ahead only; no turn zoom.
- Invalid / missing location → no camera update (existing guard).

### 6. Tuning

Expose named constants at the top of the camera helpers (offset meters vs speed, approach window vs speed, min/max camera distance) so a follow-up pass can tweak without rewriting logic.

## Testing (manual)

1. Start recording, ride/simulate motion with course: rider appears lower; more map ahead than today.
2. Increase speed: look-ahead and cruise pull-back strengthen.
3. Start navigation: same look-ahead; as you near a turn, map zooms in earlier when fast than when slow.
4. After turn advance: camera eases out.
5. Pan freely → Recenter restores policy.
6. Turn banner: distance and 2-line instruction readable at arm’s length; icon larger; off-route / recalculating still readable.
7. Idle (not recording): top-down centered behavior unchanged.

## Success criteria

- Recording follow no longer pins the rider in the vertical center; road ahead dominates.
- Approaching turns while navigating, the map closes in with speed-aware timing.
- Turn instructions are clearly more readable without a full HUD redesign.
