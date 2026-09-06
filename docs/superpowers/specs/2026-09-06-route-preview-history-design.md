# Route Preview + Destination Search History

**Date:** 2026-09-06  
**Status:** Draft for review  
**App:** MotoTripTracker iOS  

## Goal

When the rider picks a destination (search or petrol), show **multiple alternate driving routes** on the main map and require an explicit **Start** before turn-by-turn guidance begins (Google Maps–style). Keep a **search history** of picked places with swipe-to-delete.

## Decisions (approved)

| Topic | Choice |
| --- | --- |
| Alternate routes | Yes — `MKDirections` with `requestsAlternateRoutes = true` |
| Preview UI | Main ride map + bottom preview card |
| Architecture | Extend `NavigationService` (Approach A) |
| History write | When a place is **selected** (even if Start is never tapped) |
| Petrol “Go” | Same preview + Start flow |

## Current behavior (baseline)

- `DestinationSearchView` → `NavigationService.selectCompletion` → `setDestination` → `computeRoute` takes **`routes.first` only** → guidance UI immediately.
- No preview/confirm, no alternate routes, no destination search history.
- Petrol “Go” also calls `setDestination` immediately.

## Design

### Navigation phase

```text
idle ──(pick place)──► previewing ──(Start)──► navigating
  ▲                       │                      │
  └────(Cancel/clear)─────┴──────(clear)─────────┘
```

- **`idle`** — no destination; show “Set destination” overlay.
- **`previewing`** — destination + alternate routes on map; **no** step advance, voice prompts, or off-route recalculation.
- **`navigating`** — one route locked; existing turn banner, voice, off-route behavior.

### `NavigationService` changes

**New / updated state**

- `phase: NavigationPhase` (idle | previewing | navigating)
- `previewRoutes: [NavRouteOption]`
- `selectedRouteID: NavRouteOption.ID?`
- Existing `routeCoordinates` / `steps` / ETA fields apply to the **selected** option in preview, and to the active route while navigating

**`NavRouteOption`**

- `id` (stable for the preview session)
- `coordinates: [CLLocationCoordinate2D]`
- `distanceMeters: Double`
- `expectedTravelTime: TimeInterval`
- Optional short advisory string if MapKit provides one

**API flow**

1. `selectCompletion` / petrol destination / history tap  
   → resolve `MKMapItem`  
   → `DestinationSearchHistory.add(...)`  
   → `beginPreview(coordinate:name:)`  
   → `computeAlternateRoutes()` with `requestsAlternateRoutes = true`  
   → `phase = .previewing`, select first route by default  
2. `selectPreviewRoute(id:)` — update selection, map emphasis, ETA/distance on card  
3. `confirmStartNavigation()` — `phase = .navigating`, `applyRoute` for selected option (steps, polyline, callbacks)  
4. `cancelPreview()` / `clear()` — idle; clear routes and destination  

**Guards**

- `updateOrigin` guidance (step advance, voice, off-route) runs **only** when `phase == .navigating`
- While `previewing`, still update origin for map/camera and for remaining distance display of the **selected** preview route if cheap; do not recalculate off-route

### Destination search history

**Store:** `DestinationSearchHistory`  
**Persistence:** `UserDefaults.standard`, key `moto.nav.destinationHistory` (Codable JSON array)  
**Cap:** 20 entries, newest first  

**Entry fields**

- `id: UUID` (or string)
- `name: String`
- `subtitle: String?`
- `latitude` / `longitude`
- `timestamp`

**Behavior**

- Add/update on place pick (same approximate coordinate → move to top, refresh name/subtitle)
- `remove(id:)` for swipe-to-delete
- No App Group needed

### UI

**`DestinationSearchView`**

- Empty query: **Recent** list (name, subtitle); swipe-to-delete; tap → preview flow
- Non-empty query: existing `MKLocalSearchCompleter` results
- Tap result → history add → dismiss sheet → preview on main map

**`LiveRideMapView`**

- While `previewing`: draw all preview polylines; selected = strong blue / thicker; others dimmer/thinner
- Destination pin unchanged
- Fit camera to union of route bounds (or selected route) so alternatives are visible

**`RideTrackerView`**

- While `previewing`: bottom **Route preview card**
  - Destination name
  - Route chips/rows: relative label (e.g. Fastest) + duration + distance
  - **Start** (primary) / **Cancel**
- Hide turn banner / navigating route chip until Start
- After Start: existing navigating HUD
- Idle overlay when `phase == .idle`

**Petrol**

- “Go” calls the same preview entry point (not immediate `navigating`)

### Errors

- Route compute failure / empty routes: show message on preview card or brief banner; offer Cancel; do not enter `navigating`
- History decode failure: treat as empty list

### Testing (manual)

1. Search → pick place → see multiple routes (when MapKit returns them) → Start → turn guidance  
2. Cancel preview → back to idle, no guidance  
3. Switch alternate route → ETA/polyline update → Start uses selected  
4. Recent history appears; swipe delete removes; tap recent opens preview  
5. Petrol Go → same preview/Start  
6. Confirm no voice/off-route while previewing  

### Out of scope

- Traffic-aware labels beyond MapKit defaults  
- Route preferences (avoid tolls/highways)  
- Syncing history to backend / App Group widgets  
- Changing Start Ride (trip recording) coupling  

## Files likely touched

- `MotoTripTracker/Services/NavigationService.swift`
- `MotoTripTracker/UI/Tracker/DestinationSearchView.swift`
- `MotoTripTracker/UI/Tracker/RideTrackerView.swift`
- `MotoTripTracker/UI/Tracker/LiveRideMapView.swift`
- `MotoTripTracker/UI/Tracker/PetrolStationsView.swift` (Go path)
- New: `MotoTripTracker/Data/DestinationSearchHistory.swift` (or under Services/)
- Optional README / Project-Guide one-liners after ship

## Success criteria

- Rider always sees route options and confirms Start before turn-by-turn begins  
- Search history persists across launches and is deletable  
- Petrol and search share one preview pipeline  
- Existing navigating behavior remains intact after Start  
