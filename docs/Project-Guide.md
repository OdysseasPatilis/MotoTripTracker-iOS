# MotoTripTracker — Project Guide (iOS beginners)

A full tour of this iPhone app: what it does, how the folders fit together, which Apple frameworks it uses, and **where to read the code**. Written for someone new to iOS development.

Related docs:
- [`README.md`](../README.md) — feature list and quick architecture diagram  
- [`docs/RND-Backend.md`](RND-Backend.md) — future backend / live-share R&D  

Last updated: 2026-08-30

---

## Table of contents

1. [What this app is](#1-what-this-app-is)
2. [iOS concepts you need first](#2-ios-concepts-you-need-first)
3. [How to open and run](#3-how-to-open-and-run)
4. [Targets & identifiers](#4-targets--identifiers)
5. [Folder map (every important file)](#5-folder-map-every-important-file)
6. [App launch & dependency wiring](#6-app-launch--dependency-wiring)
7. [Screens & navigation](#7-screens--navigation)
8. [Live ride loop](#8-live-ride-loop)
9. [Domain algorithms](#9-domain-algorithms)
10. [Speed limits (OSM / Overpass)](#10-speed-limits-osm--overpass)
11. [Navigation, voice, petrol, weather, fuel](#11-navigation-voice-petrol-weather-fuel)
12. [Persistence (SwiftData)](#12-persistence-swiftdata)
13. [History, summary, share, replay](#13-history-summary-share-replay)
14. [Widgets & Live Activities](#14-widgets--live-activities)
15. [Theme, splash, logging](#15-theme-splash-logging)
16. [Permissions & background](#16-permissions--background)
17. [External APIs (no Google Maps key)](#17-external-apis-no-google-maps-key)
18. [Tests & scripts](#18-tests--scripts)
19. [Suggested reading order](#19-suggested-reading-order)
20. [Glossary](#20-glossary)

---

## 1. What this app is

**MotoTripTracker** is a SwiftUI motorcycle ride tracker for iPhone. It:

- Records GPS rides (including with the screen locked, if **Always** location is granted)
- Shows live speed, road speed limits, navigation HUD, fuel range, petrol suggestions, route weather
- Saves rides locally with physics stats (G-force, corners, twistiness)
- Lets you review history, personal leaderboards, share a card / GPX, and replay routes
- Shows a **Live Activity** on the Lock Screen / Dynamic Island and Home Screen widgets

It is the iOS counterpart of an Android **MotoTripTracker** app. Domain ideas (trip loop, filters, Overpass limits) mirror that project; the stack here is **SwiftUI + SwiftData + MapKit + Core Location**.

There is **no custom backend yet**. Everything durable lives on the device (SwiftData). See `docs/RND-Backend.md` for planned cloud / buddy-share ideas.

**Bundle ID:** `com.odys.MotoTripTracker`  
**Deployment target:** iOS 26.4 (see Xcode project `IPHONEOS_DEPLOYMENT_TARGET`)

---

## 2. iOS concepts you need first

If you are new to Apple platforms, these ideas appear everywhere in this repo:

| Concept | What it means here | Where you see it |
| --- | --- | --- |
| **Xcode project** | `.xcodeproj` holds targets, build settings, schemes | `MotoTripTracker.xcodeproj` |
| **Target** | A build product (app, tests, widget extension) | App, Tests, UITests, Widgets |
| **SwiftUI** | Declarative UI (`View`, `body`, modifiers) | Everything under `UI/` |
| **`@main` App** | Process entry point | `MotoTripTrackerApp.swift` |
| **`NavigationStack`** | Push/pop screens with typed routes | `RootNavigationView.swift` |
| **Environment** | Pass shared objects down the view tree | `.environment(container)` |
| **`@Observable` / `@MainActor`** | Modern observation; UI work on main thread | `AppContainer`, services, `TripManager` |
| **SwiftData** | Apple’s ORM / local DB (`@Model`) | `Trip`, `RoutePoint`, `TripRepository` |
| **Core Location** | GPS via `CLLocationManager` | `LocationService.swift` |
| **MapKit** | Apple maps, directions, search | `LiveRideMapView`, `NavigationService` |
| **App Group** | Shared container between app + widget | `MotoTripTrackerShared/AppGroup.swift` |
| **WidgetKit / ActivityKit** | Home Screen widgets + Live Activities | `MotoTripTrackerWidgets/` |
| **Entitlements** | Capabilities (App Groups, etc.) | `*.entitlements` |
| **Info.plist / build keys** | Permissions strings, background modes | Project build settings + `Info.plist` |
| **Scheme** | What Xcode Runs (`⌘R`) | Shared `MotoTripTracker` scheme |

**Mental model:** Views draw UI. `AppContainer` owns services. GPS arrives in `LocationService` → fans out to trip / speed limit / nav / fuel → UI observes `@Observable` state and re-renders.

---

## 3. How to open and run

1. Open `MotoTripTracker.xcodeproj` in **Xcode**  
2. Select the **MotoTripTracker** scheme (not the Widgets scheme alone)  
3. Pick a simulator or a real iPhone  
4. Press **Run** (`⌘R`)

**On a real device for rides:**
- Grant location → eventually **Always** (When In Use alone stops GPS when the screen locks)
- Enable Live Activities in Settings if you want Lock Screen updates
- Add widgets: long-press Home Screen → Widgets → MotoTripTracker

**Unit tests:** Product → Test, or:

```bash
xcodebuild -scheme MotoTripTracker \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:MotoTripTrackerTests test
```

---

## 4. Targets & identifiers

| Target | Product | Bundle ID | Role |
| --- | --- | --- | --- |
| **MotoTripTracker** | iOS app | `com.odys.MotoTripTracker` | Main UI + ride logic |
| **MotoTripTrackerWidgets** | App extension | `com.odys.MotoTripTracker.Widgets` | Live Activity UI + Home Screen widgets |
| **MotoTripTrackerTests** | Unit tests | `…Tests` | Domain/service tests |
| **MotoTripTrackerUITests** | UI tests | `…UITests` | Launch / UI automation |

**Shared code** between app and widgets lives in `MotoTripTrackerShared/` (compiled into both).

**App Group:** `group.com.odys.MotoTripTracker`  
Sources: `MotoTripTracker/MotoTripTracker.entitlements`, `MotoTripTrackerWidgets/MotoTripTrackerWidgets.entitlements`, `MotoTripTrackerShared/AppGroup.swift`

---

## 5. Folder map (every important file)

```
MotoTripTracker/                          # Main app sources
├── MotoTripTrackerApp.swift              # @main entry, splash + warm-up
├── AppContainer.swift                    # DI / composition root
├── Domain/                               # Pure-ish ride algorithms
├── Data/                                 # SwiftData models + repository
├── Services/                             # GPS, Overpass, nav, fuel, widgets bridge
├── UI/                                   # SwiftUI screens
└── Utilities/                            # Logging, GPX, formatters, share

MotoTripTrackerShared/                    # App ↔ widget shared types
MotoTripTrackerWidgets/                   # WidgetKit extension
MotoTripTrackerTests/                     # Unit tests
MotoTripTrackerUITests/                   # UI tests
Scripts/                                  # Athens speed-limit pack builder
docs/                                     # This guide + backend R&D
Resources/ (in app)                       # athens_speed_limits.json
```

### Domain (`MotoTripTracker/Domain/`)

| File | Responsibility |
| --- | --- |
| `TripManager.swift` | Orchestrates start/pause/resume/stop; processes each GPS fix |
| `RideSessionState.swift` | Live session snapshot: stats + active/paused flags |
| `TripStats.swift` | Live metrics + `GpsQuality` |
| `SpeedFilter.swift` | Reject bad accuracy; kill GPS drift under ~3 km/h |
| `SpeedSmoother.swift` | Smooth display speed |
| `StopDetector.swift` | Split moving vs stopped time |
| `ElevationSmoother.swift` | Filter elevation noise; accumulate gain |
| `GForceTracker.swift` | Longitudinal G from speed deltas |
| `CornerDetector.swift` | Detect corners from bearing changes |
| `TwistinessCalculator.swift` | Score 0–100 + rating labels |
| `RideDistanceFilter.swift` | Discard trips under 50 m on stop |
| `RideMoments.swift` | Post-ride highlight moments |
| `RouteReplayEngine.swift` | Playback engine for full route view |

### Data (`MotoTripTracker/Data/`)

| File | Responsibility |
| --- | --- |
| `Models/Trip.swift` | `@Model` saved ride |
| `Models/RoutePoint.swift` | `@Model` GPS sample (+ waypoint fields) |
| `TripRepository.swift` | Create/update/query/delete trips |
| `WaypointAnalyzer.swift` | After stop: mark start/end, peak speed, summit, stops… |

### Services (`MotoTripTracker/Services/`)

| File | Responsibility |
| --- | --- |
| `LocationService.swift` | `CLLocationManager` wrapper, Always auth, background flag |
| `SpeedLimitService.swift` | Pack → cache → Overpass pipeline |
| `SpeedLimitRegionPack.swift` | Bundled Athens grid pack |
| `SpeedLimitCacheStore.swift` | Disk cache of grid cells |
| `OSMMaxSpeedParser.swift` | Parse OSM `maxspeed` + implied GR defaults |
| `NavigationService.swift` | Search, `MKDirections`, turn steps, off-route |
| `NavigationVoicePrompt.swift` | `AVSpeechSynthesizer` turn announcements |
| `FuelService.swift` | Tank, burn from distance, range, low fuel |
| `PetrolPreferences.swift` | Saved brand order / octane |
| `PetrolSearchStrategy.swift` | Adaptive search radius (city / rural / highway) |
| `PetrolStationFinder.swift` | Overpass + MapKit petrol results |
| `RouteWeatherService.swift` | Open-Meteo along route |
| `RideLiveActivityController.swift` | Start/update/end ActivityKit activity |
| `RideWidgetSnapshotPublisher.swift` | Write App Group snapshot; reload timelines |

### UI (`MotoTripTracker/UI/`)

| Path | Screen |
| --- | --- |
| `Navigation/RootNavigationView.swift` | `NavigationStack` + `AppRoute` |
| `Navigation/AppNavigate.swift` | Environment helper to push routes |
| `Tracker/RideTrackerView.swift` | Main dashboard (map + speedo + HUD) |
| `Tracker/LiveRideMapView.swift` | MapKit live map, trail, camera |
| `Tracker/DestinationSearchView.swift` | Destination autocomplete sheet |
| `Tracker/PetrolStationsView.swift` | Petrol recommendation list |
| `Tracker/RouteWeatherView.swift` | Weather timeline sheet |
| `Tracker/FuelSettingsView.swift` | Tank / consumption / fill-up |
| `History/RideHistoryView.swift` | Ride list, search, favorites |
| `Leaderboard/RideLeaderboardView.swift` | Personal rankings |
| `Summary/RideSummaryView.swift` | Stats, moments, share, open route |
| `Route/FullRouteView.swift` | Colored route + replay |
| `Splash/SplashView.swift` | Launch splash |
| `Theme/AppTheme.swift` | Light/dark + brand palette |

### Utilities

| File | Responsibility |
| --- | --- |
| `AppLogger.swift` | `os.Logger` categories + `LogThrottle` |
| `RideFormatters.swift` | Dates, distances, speeds for UI |
| `PolylineEncoder.swift` | Encode/decode route polylines |
| `GpxExporter.swift` | GPX file export |
| `RideShareHelper.swift` | Share card image generation |
| `OpeningHoursEvaluator.swift` | OSM opening_hours → open/closed |

### Shared + widgets

| File | Responsibility |
| --- | --- |
| `AppGroup.swift` | Suite name + `UserDefaults` |
| `RideActivityAttributes.swift` | ActivityKit attributes / content state |
| `RideWidgetSnapshot.swift` | Last ride + week stats payload |
| `RideLiveActivityWidget.swift` | Lock Screen / Dynamic Island UI |
| `LastRideWidget.swift` / `WeekStatsWidget.swift` | Home Screen widgets |
| `MotoTripTrackerWidgetsBundle.swift` | Widget bundle entry |

---

## 6. App launch & dependency wiring

### Entry point

**Source:** `MotoTripTracker/MotoTripTrackerApp.swift`

```swift
@main
struct MotoTripTrackerApp: App { ... }
```

What happens on launch:

1. Creates `AppContainer` (`@State`)
2. Shows `RootNavigationView` **under** the splash (opacity kept live so MapKit/SwiftData warm up)
3. Shows `SplashView` until dismissed
4. Injects `container`, `theme`, and `modelContainer` into the environment
5. Calls `container.warmUpForFirstInteraction()` (touches trip list + search completer)

### Composition root

**Source:** `MotoTripTracker/AppContainer.swift`

`AppContainer` is the **single place** that constructs and connects:

- SwiftData `ModelContainer` for `Trip` + `RoutePoint`
- `TripRepository`, `TripManager`
- `LocationService`, `SpeedLimitService`, `NavigationService`
- `FuelService`, `PetrolPreferences`, `RouteWeatherService`
- `ThemeStore`

Critical wiring — every GPS fix fans out:

```text
locationService.onLocationUpdate
  → tripManager.onLocationUpdate
  → speedLimitService.refresh
  → navigationService.updateOrigin
  → fuelService.updateConsumedDistance (if riding)
  → routeWeatherService.refreshAhead (if navigating)
  → pushLiveActivityUpdate
```

Ride lifecycle APIs used by the UI:

| Method | Effect |
| --- | --- |
| `startRide()` | Always auth request, reset limits/fuel, start trip + GPS + Live Activity |
| `pauseRide()` / `resumeRide()` | Pause/resume session |
| `stopRide()` | Finalize or discard short ride; end Live Activity; refresh widgets |
| `resumeBackgroundTrackingIfNeeded()` | Re-assert tracking when returning to foreground |

**Beginner tip:** In larger iOS apps this pattern is often called a composition root or lightweight DI. Views should not construct `CLLocationManager` themselves — they talk to `AppContainer`.

---

## 7. Screens & navigation

**Sources:**
- `UI/Navigation/RootNavigationView.swift`
- `UI/Navigation/AppNavigate.swift`
- `UI/Tracker/RideTrackerView.swift`

### Route enum

```swift
enum AppRoute: Hashable {
    case history
    case leaderboard
    case summary(UUID)
    case fullRoute(UUID)
}
```

Root is always `RideTrackerView`. Other screens are pushed via `NavigationStack` + `path.append`. Menu items use `appNavigate` so deep links don’t break History-first navigation.

### Main dashboard (`RideTrackerView`)

HUD-style layout (nav bar often hidden while riding):

- Top: `LiveRideMapView` (~46% height) with overlays (GPS, battery, range, nav HUD)
- Bottom: neon speedometer, European-style limit badge, stats grid, Start/Pause/Stop
- Sheets: destination search, petrol, weather, fuel settings
- Options menu (when idle): History, Leaderboard, theme

**Nav HUD layout:**
- **Top card:** next turn (distance + instruction)
- **Bottom chip:** ETA / remaining, weather glyph, voice mute, Apple Maps, clear

Spoken turns: `NavigationVoicePrompt` (~250 m approach + on step advance); mute persisted.

---

## 8. Live ride loop

```text
User taps Start
  → AppContainer.startRide()
  → LocationService.startUpdating()
  → CLLocationManager delivers CLLocation
  → AppContainer callback
  → TripManager processes fix → updates RideSessionState
  → SwiftUI observes sessionState / services → UI updates
User taps Stop
  → TripManager.stopTrip()
  → if distance < 50 m: discard; else save + polyline + waypoints
```

### Location service

**Source:** `Services/LocationService.swift`

- Uses `CLLocationManager` with `kCLLocationAccuracyBestForNavigation`
- `activityType = .automotiveNavigation`
- `pausesLocationUpdatesAutomatically = false`
- Enables `allowsBackgroundLocationUpdates` only when **Always** is granted
- Exposes `updateTick` because `CLLocation` is not `Equatable` (views need a refresh signal)

### Trip manager

**Source:** `Domain/TripManager.swift`

Per valid fix roughly:

1. `SpeedFilter.isValid` (accuracy ≤ 15 m)
2. Derive speed; smooth for display
3. Update moving/stopped time (`StopDetector`)
4. Distance + elevation gain
5. Longitudinal G (`GForceTracker`)
6. Corners + lateral G (`CornerDetector`)
7. Persist a `RoutePoint`; append to live `routeCoordinates` for the mint trail
8. Publish new `RideSessionState` / `TripStats`

**Minimum save distance:** 50 m (`TripManager.minSaveDistanceMeters` / `RideDistanceFilter`).

---

## 9. Domain algorithms

These types are mostly framework-light (easy to unit test).

| Algorithm | Source | Idea |
| --- | --- | --- |
| GPS validity | `SpeedFilter.swift` | Accuracy ≤ 15 m; ignore speeds &lt; ~0.83 m/s |
| Display speed | `SpeedSmoother.swift` | Smooth km/h while moving |
| Moving vs stopped | `StopDetector.swift` | Accumulate timers from `isMoving` |
| Teleport rejection | inside `TripManager` | Ignore huge jumps (e.g. &gt; 80 m) |
| Elevation | `ElevationSmoother.swift` | Reduce barometric/GPS noise |
| Long G | `GForceTracker.swift` | Δv / Δt, clamped (handlebar vibration resistant) |
| Corners | `CornerDetector.swift` | Bearing change while moving |
| Lateral G | via corner radius | \(v^2 / r\) |
| Twistiness | `TwistinessCalculator.swift` | 72% corner density + 28% peak lateral G → 0–100 |
| Moments | `RideMoments.swift` | Peak rush, climbs, pauses, cruise, twistiness windows |
| Replay | `RouteReplayEngine.swift` | Time-based playback 1×–4× |

Twistiness ratings: *Straight* → *Flowing* → *Twisty* → *Epic twisties* (`TwistinessCalculator.Rating`).

---

## 10. Speed limits (OSM / Overpass)

**Sources:**
- `Services/SpeedLimitService.swift`
- `Services/SpeedLimitRegionPack.swift`
- `Services/SpeedLimitCacheStore.swift`
- `Services/OSMMaxSpeedParser.swift`
- `Resources/athens_speed_limits.json`
- `Scripts/build_athens_speed_limit_pack.py`

### Pipeline

1. **Bundled Greater Athens pack** (~4k grid cells) if inside bbox  
2. If cell empty **or** pack limit looks implausible vs GPS speed → fall through  
3. Throttle network (~25 m and ~8 s)  
4. Check **disk grid cache** (+ neighbors)  
5. Query **Overpass mirrors** with expanding radii `[40, 80, 160, 280]` m  
6. Parse `maxspeed`; if missing, use **implied Greek highway defaults**  
7. Prefer higher-priority highway types when several ways match  
8. Default UI fallback if nothing known: **50 km/h** (`effectiveLimitKmh`)

Manual override was removed; leftover `moto_manual_speed_limit` UserDefaults is cleared on init.

Over-limit UX: flashing sign + translucent dashboard flash in `RideTrackerView`.

Rebuild Athens pack:

```bash
python3 Scripts/build_athens_speed_limit_pack.py
```

---

## 11. Navigation, voice, petrol, weather, fuel

### Navigation

**Source:** `Services/NavigationService.swift`

- `MKLocalSearchCompleter` for destination search  
- `MKDirections` for driving route + steps → `NavStep`  
- Tracks distance to next maneuver, remaining distance, ETA  
- Off-route ~**80 m** from polyline → recalculate (with cooldown)  
- Callbacks `onRouteApplied` / `onRouteCleared` refresh weather  

**Voice:** `Services/NavigationVoicePrompt.swift` (`AVSpeechSynthesizer`, prefers `el-GR` when available).

**UI:** top turn card + bottom chip in `RideTrackerView`; map polyline in `LiveRideMapView`.

### Petrol

**Sources:** `PetrolStationFinder.swift`, `PetrolSearchStrategy.swift`, `PetrolPreferences.swift`, `UI/Tracker/PetrolStationsView.swift`, `OpeningHoursEvaluator.swift`

- Overpass for amenity=fuel (+ opening hours when tagged)  
- MapKit enrichment for names/address  
- Rank: preferred brands → octane → open status → distance  
- Radius adapts: tighter in cities, wider rural, highway-biased when fast  
- **Details** → Apple place card; **Go** → in-app nav  

### Route weather

**Source:** `Services/RouteWeatherService.swift` + `UI/Tracker/RouteWeatherView.swift`  
Uses **Open-Meteo** (no API key): samples forecast along the route at estimated arrival times.

### Fuel / range

**Source:** `Services/FuelService.swift` + `UI/Tracker/FuelSettingsView.swift`

- Persisted tank capacity, remaining liters, L/100 km  
- Burns fuel from trip distance while riding  
- Low fuel under ~20% tank or ~40 km range  
- Can surface on Live Activity summary line when no nav destination  

---

## 12. Persistence (SwiftData)

**Sources:** `Data/Models/Trip.swift`, `Data/Models/RoutePoint.swift`, `Data/TripRepository.swift`

### `Trip` (one saved ride)

Important fields: times, distance, moving/stopped, max/avg speed, max G, elevation gain, encoded polyline, title, favorite, max lateral G, corner count, twistiness score.

Relationship: `routePoints` with **cascade delete**.

### `RoutePoint` (GPS sample)

lat/lon/altitude/speed/timestamp + optional waypoint metadata (`waypointType`, titles).

### Repository duties

- `startNewTrip` / append points during ride  
- Finalize stats + polyline on stop  
- Query all / favorites / by id  
- Rename, favorite toggle, delete  
- Kick off `WaypointAnalyzer` after save  

Data is **local only** (no iCloud sync in this codebase yet).

---

## 13. History, summary, share, replay

| Feature | Source |
| --- | --- |
| History list / search / date filters / favorites | `UI/History/RideHistoryView.swift` |
| Personal leaderboard (speed, distance, turns, twistiness) | `UI/Leaderboard/RideLeaderboardView.swift` |
| Summary stats + moments | `UI/Summary/RideSummaryView.swift`, `Domain/RideMoments.swift` |
| Share card image | `Utilities/RideShareHelper.swift` |
| GPX export | `Utilities/GpxExporter.swift` |
| Full route map (speed/elevation gradient) | `UI/Route/FullRouteView.swift` |
| Waypoints on route | `Data/WaypointAnalyzer.swift` |
| Replay play/pause/scrub | `Domain/RouteReplayEngine.swift` + `FullRouteView` |

Leaderboard is **personal** (your rides only), not a global social board.

---

## 14. Widgets & Live Activities

### Why an App Group?

The main app and the widget extension are **separate processes**. They share data via App Group UserDefaults:

**Sources:** `MotoTripTrackerShared/AppGroup.swift`, `RideWidgetSnapshot.swift`, `Services/RideWidgetSnapshotPublisher.swift`

When a trip is saved (or on launch), the app writes a snapshot and asks WidgetKit to reload timelines.

### Live Activity

**Sources:**
- Attributes: `MotoTripTrackerShared/RideActivityAttributes.swift`
- Controller: `Services/RideLiveActivityController.swift`
- UI: `MotoTripTrackerWidgets/RideLiveActivityWidget.swift`

Content state includes speed, limit, distance, moving time, paused, over-limit, optional nav/fuel summary. Updates throttled (~1 Hz) from `AppContainer.pushLiveActivityUpdate`.

### Home Screen widgets

- `LastRideWidget.swift` — last saved ride  
- `WeekStatsWidget.swift` — week aggregate  

Brand colors: `WidgetBrand.swift`. Bundle entry: `MotoTripTrackerWidgetsBundle.swift`.

---

## 15. Theme, splash, logging

| Concern | Source |
| --- | --- |
| Light/dark + mint/green/blue palette | `UI/Theme/AppTheme.swift` (`ThemeStore`) |
| Splash overlay | `UI/Splash/SplashView.swift` |
| Launch background color | `Assets.xcassets/LaunchBackground`, `Info.plist` `UILaunchScreen` |
| Structured logging | `Utilities/AppLogger.swift` |

Logger categories include: `App`, `Location`, `Trip`, `Persistence`, `SpeedLimit`, `Navigation`, `Waypoint`, `Sensors`. `LogThrottle` prevents 1 Hz GPS from flooding the console.

---

## 16. Permissions & background

Configured mainly in **Xcode target build settings** (not a huge hand-written Info.plist):

| Key / setting | Purpose |
| --- | --- |
| `NSLocationWhenInUseUsageDescription` | Foreground tracking explanation |
| `NSLocationAlwaysAndWhenInUseUsageDescription` | Background / lock-screen recording |
| `UIBackgroundModes = location` | Allows background location updates |

**Important product rule:** **When In Use is not enough** for locked-screen rides. Without Always, GPS stops, the ride clock freezes, and Live Activity can look stale. The dashboard warns and can open Settings (`LocationService.openSystemLocationSettings()`).

Entitlement for sharing with widgets: App Groups (see §4).

---

## 17. External APIs (no Google Maps key)

| Need | Provider | Code |
| --- | --- | --- |
| Map display | Apple MapKit | `LiveRideMapView`, etc. |
| Directions / search | Apple MapKit (`MKDirections`, `MKLocalSearchCompleter`) | `NavigationService` |
| Speed limits | OpenStreetMap via Overpass HTTP | `SpeedLimitService` |
| Petrol + hours | Overpass + MapKit | `PetrolStationFinder` |
| Weather | Open-Meteo | `RouteWeatherService` |

Overpass mirrors (from `SpeedLimitService`):

- `https://lz4.overpass-api.de/api/interpreter`  
- `https://z.overpass-api.de/api/interpreter`  
- `https://overpass.kumi.systems/api/interpreter`  
- `https://overpass-api.de/api/interpreter`  

Be polite: the app already throttles by distance/time. Don’t hammer mirrors from scripts without backoff.

---

## 18. Tests & scripts

### Unit tests

**Source:** `MotoTripTrackerTests/MotoTripTrackerTests.swift`

Uses Swift Testing (`import Testing`, `@Test`). Covers filters, stop detector, parsers, twistiness, and other domain behavior. Good place to learn how pieces behave without running the full UI.

### UI tests

**Sources:** `MotoTripTrackerUITests/*.swift` — launch/smoke style tests.

### Scripts

`Scripts/build_athens_speed_limit_pack.py` — rebuilds `Resources/athens_speed_limits.json` from Overpass/OSM data for offline Athens limits.

---

## 19. Suggested reading order

For a new iOS developer learning *this* codebase:

1. **`MotoTripTrackerApp.swift`** — how an app starts  
2. **`AppContainer.swift`** — how pieces connect  
3. **`RootNavigationView.swift` + `RideTrackerView.swift`** — UI structure  
4. **`LocationService.swift` + `TripManager.swift`** — the heartbeat of the product  
5. **`Trip.swift` + `TripRepository.swift`** — what gets saved  
6. **`SpeedLimitService.swift`** — network + cache pattern  
7. **`NavigationService.swift`** — MapKit directions pattern  
8. **`RideActivityAttributes.swift` + widget files** — multi-target sharing  
9. **`MotoTripTrackerTests.swift`** — behavior without the UI  
10. **`docs/RND-Backend.md`** — where the product may go next  

When stuck on an Apple API, search Apple’s docs for the type name (`CLLocationManager`, `ModelContainer`, `ActivityKit`, `MKDirections`).

---

## 20. Glossary

| Term | Meaning in this project |
| --- | --- |
| **Fix** | One GPS sample (`CLLocation`) |
| **Session** | In-progress ride (`RideSessionState`) |
| **Trip** | Saved ride record (`Trip` model) |
| **Polyline** | Compressed lat/lon string for the path |
| **Overpass** | Query API over OpenStreetMap data |
| **Region pack** | Bundled offline speed-limit grid (Athens) |
| **Live Activity** | Lock Screen / Dynamic Island live ride UI |
| **App Group** | Shared storage between app and extension |
| **Twistiness** | Composite “how bendy / spirited” score |
| **HUD** | Glanceable overlays on the map while riding |
| **Composition root** | `AppContainer` — wires dependencies once |

---

## Quick “where is X?” index

| I want to change… | Start here |
| --- | --- |
| Start/stop buttons / speedo UI | `UI/Tracker/RideTrackerView.swift` |
| Map camera / trail color | `UI/Tracker/LiveRideMapView.swift` |
| What happens each GPS second | `AppContainer` callback + `TripManager.onLocationUpdate` |
| Background GPS | `LocationService` + Always permission strings |
| Speed limit number on the sign | `SpeedLimitService.effectiveLimitKmh` |
| Turn banner / voice | `RideTrackerView` + `NavigationService` + `NavigationVoicePrompt` |
| Saved ride fields | `Data/Models/Trip.swift` |
| History list | `UI/History/RideHistoryView.swift` |
| Share image | `Utilities/RideShareHelper.swift` |
| Lock Screen live ride | `RideLiveActivityController` + `RideLiveActivityWidget` |
| Home Screen widget data | `RideWidgetSnapshotPublisher` |
| Colors / dark mode | `UI/Theme/AppTheme.swift` |
| Future server / buddy share | `docs/RND-Backend.md` |

---

*This document describes the codebase as of the date above. When behavior and docs disagree, trust the Swift sources listed here.*
