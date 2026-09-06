# Route Preview + Destination History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show multiple alternate driving routes on the main map after picking a destination, require Start before turn-by-turn guidance, and persist deletable destination search history.

**Architecture:** Extend `NavigationService` with `idle | previewing | navigating` phases. `MKDirections` uses `requestsAlternateRoutes = true` for initial preview; guidance (steps, voice, off-route) runs only in `navigating`. History is a small Codable `UserDefaults` store written when a place is selected.

**Tech Stack:** SwiftUI, MapKit (`MKDirections`, `MKLocalSearchCompleter`), Swift Testing, UserDefaults

## Global Constraints

- Follow Approach A from `docs/superpowers/specs/2026-09-06-route-preview-history-design.md`
- History key: `moto.nav.destinationHistory`; cap **20** entries; write on **place select**
- Petrol **Go** uses the same preview + Start pipeline
- Do not start voice / step advance / off-route recalculation while `previewing`
- Project uses `PBXFileSystemSynchronizedRootGroup` — new files under `MotoTripTracker/` and `MotoTripTrackerTests/` are picked up automatically
- Prefer `xcodebuild -scheme MotoTripTracker -destination 'generic/platform=iOS' build` when simulator destinations are unavailable; run unit tests when a simulator is available

---

## File map

| File | Responsibility |
| --- | --- |
| `MotoTripTracker/Data/DestinationSearchHistory.swift` | Codable recent destinations + UserDefaults CRUD |
| `MotoTripTracker/Services/NavigationService.swift` | Phase machine, alternate routes, preview/start/cancel APIs |
| `MotoTripTracker/UI/Tracker/DestinationSearchView.swift` | Recent list + swipe delete + select → preview |
| `MotoTripTracker/UI/Tracker/LiveRideMapView.swift` | Draw all preview polylines (selected emphasized) |
| `MotoTripTracker/UI/Tracker/RideTrackerView.swift` | Preview card (route chips, Start, Cancel); gate navigating HUD |
| `MotoTripTracker/UI/Tracker/PetrolStationsView.swift` | Go → preview (not immediate navigating) |
| `MotoTripTrackerTests/MotoTripTrackerTests.swift` | History + phase-related unit tests |
| `README.md` | One-liner for preview + history |

---

### Task 1: Destination search history store

**Files:**
- Create: `MotoTripTracker/Data/DestinationSearchHistory.swift`
- Modify: `MotoTripTrackerTests/MotoTripTrackerTests.swift`

**Interfaces:**
- Produces:
  - `struct DestinationHistoryEntry: Codable, Identifiable, Equatable, Sendable` with `id: UUID`, `name: String`, `subtitle: String`, `latitude: Double`, `longitude: Double`, `timestamp: TimeInterval`
  - `enum DestinationSearchHistory` with `static func all(defaults: UserDefaults = .standard) -> [DestinationHistoryEntry]`, `static func add(name:subtitle:latitude:longitude:defaults:)`, `static func remove(id:defaults:)`, `static let maxEntries = 20`, `static let storageKey = "moto.nav.destinationHistory"`

- [ ] **Step 1: Write the failing tests**

Add to `MotoTripTrackerTests/MotoTripTrackerTests.swift`:

```swift
@Test func destinationHistoryAddsNewestFirstAndCapsAt20() {
    let defaults = UserDefaults(suiteName: "test.moto.nav.history.\(UUID().uuidString)")!
    defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }

    for i in 0..<25 {
        DestinationSearchHistory.add(
            name: "Place \(i)",
            subtitle: "Sub \(i)",
            latitude: 37.9 + Double(i) * 0.001,
            longitude: 23.7,
            defaults: defaults
        )
    }
    let all = DestinationSearchHistory.all(defaults: defaults)
    #expect(all.count == 20)
    #expect(all.first?.name == "Place 24")
    #expect(all.last?.name == "Place 5")
}

@Test func destinationHistoryDedupesNearbyCoordinateToTop() {
    let defaults = UserDefaults(suiteName: "test.moto.nav.history.dedupe.\(UUID().uuidString)")!
    defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }

    DestinationSearchHistory.add(
        name: "Old",
        subtitle: "A",
        latitude: 37.9800,
        longitude: 23.7200,
        defaults: defaults
    )
    DestinationSearchHistory.add(
        name: "Other",
        subtitle: "B",
        latitude: 38.0,
        longitude: 24.0,
        defaults: defaults
    )
    DestinationSearchHistory.add(
        name: "Updated",
        subtitle: "C",
        latitude: 37.98001,
        longitude: 23.72001,
        defaults: defaults
    )
    let all = DestinationSearchHistory.all(defaults: defaults)
    #expect(all.count == 2)
    #expect(all[0].name == "Updated")
    #expect(all[0].subtitle == "C")
}

@Test func destinationHistoryRemoveById() {
    let defaults = UserDefaults(suiteName: "test.moto.nav.history.remove.\(UUID().uuidString)")!
    defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }

    DestinationSearchHistory.add(
        name: "Keep",
        subtitle: "",
        latitude: 1,
        longitude: 2,
        defaults: defaults
    )
    DestinationSearchHistory.add(
        name: "Drop",
        subtitle: "",
        latitude: 3,
        longitude: 4,
        defaults: defaults
    )
    let dropID = DestinationSearchHistory.all(defaults: defaults).first { $0.name == "Drop" }!.id
    DestinationSearchHistory.remove(id: dropID, defaults: defaults)
    let names = DestinationSearchHistory.all(defaults: defaults).map(\.name)
    #expect(names == ["Keep"])
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -scheme MotoTripTracker \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:MotoTripTrackerTests/MotoTripTrackerTests/destinationHistoryAddsNewestFirstAndCapsAt20 \
  test
```

Expected: compile error or FAIL — `DestinationSearchHistory` not found.

If simulator is unavailable, proceed to implement, then build with `generic/platform=iOS` and run tests when a simulator is free.

- [ ] **Step 3: Implement `DestinationSearchHistory`**

Create `MotoTripTracker/Data/DestinationSearchHistory.swift`:

```swift
import Foundation

struct DestinationHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var subtitle: String
    var latitude: Double
    var longitude: Double
    var timestamp: TimeInterval
}

enum DestinationSearchHistory {
    static let storageKey = "moto.nav.destinationHistory"
    static let maxEntries = 20
    /// ~25 m — treat as the same place for dedupe.
    private static let dedupeDegrees = 0.00025

    static func all(defaults: UserDefaults = .standard) -> [DestinationHistoryEntry] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([DestinationHistoryEntry].self, from: data)) ?? []
    }

    static func add(
        name: String,
        subtitle: String,
        latitude: Double,
        longitude: Double,
        defaults: UserDefaults = .standard
    ) {
        var items = all(defaults: defaults)
        items.removeAll {
            abs($0.latitude - latitude) < dedupeDegrees
                && abs($0.longitude - longitude) < dedupeDegrees
        }
        let entry = DestinationHistoryEntry(
            id: UUID(),
            name: name,
            subtitle: subtitle,
            latitude: latitude,
            longitude: longitude,
            timestamp: Date().timeIntervalSince1970
        )
        items.insert(entry, at: 0)
        if items.count > maxEntries {
            items = Array(items.prefix(maxEntries))
        }
        save(items, defaults: defaults)
    }

    static func remove(id: UUID, defaults: UserDefaults = .standard) {
        var items = all(defaults: defaults)
        items.removeAll { $0.id == id }
        save(items, defaults: defaults)
    }

    private static func save(_ items: [DestinationHistoryEntry], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Same `xcodebuild … test` command as Step 2 (or run the three history tests).  
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add MotoTripTracker/Data/DestinationSearchHistory.swift MotoTripTrackerTests/MotoTripTrackerTests.swift
git commit -m "$(cat <<'EOF'
feat: add destination search history store

EOF
)"
```

---

### Task 2: NavigationService preview phase + alternate routes

**Files:**
- Modify: `MotoTripTracker/Services/NavigationService.swift`

**Interfaces:**
- Consumes: `DestinationSearchHistory.add`
- Produces:
  - `enum NavigationPhase: String, Equatable { case idle, previewing, navigating }`
  - `struct NavRouteOption: Identifiable, Equatable` with `id: UUID`, `coordinates: [CLLocationCoordinate2D]`, `distanceMeters: Double`, `expectedTravelTime: TimeInterval`, `steps: [NavStep]`
  - `private(set) var phase: NavigationPhase`
  - `private(set) var previewRoutes: [NavRouteOption]`
  - `private(set) var selectedRouteID: UUID?`
  - `var selectedPreviewRoute: NavRouteOption?`
  - `func beginPreview(coordinate:name:subtitle:)`
  - `func selectPreviewRoute(id: UUID)`
  - `func confirmStartNavigation()`
  - `func cancelPreview()`
  - Keep `setDestination` as a thin wrapper that calls `beginPreview` (petrol/search compatibility) **or** replace call sites in later tasks — prefer renaming call sites to `beginPreview` and make `setDestination` call `beginPreview(coordinate:name:subtitle: "")` for one release

- [ ] **Step 1: Add types and published preview state near the top of `NavigationService.swift`**

After `NavStep`, add:

```swift
enum NavigationPhase: String, Equatable, Sendable {
    case idle
    case previewing
    case navigating
}

struct NavRouteOption: Identifiable, Equatable, Sendable {
    let id: UUID
    let coordinates: [CLLocationCoordinate2D]
    let distanceMeters: Double
    let expectedTravelTime: TimeInterval
    let steps: [NavStep]

    static func == (lhs: NavRouteOption, rhs: NavRouteOption) -> Bool {
        lhs.id == rhs.id
    }
}
```

Note: `CLLocationCoordinate2D` is not `Equatable` in all SDKs — identity via `id` is enough for `NavRouteOption` equality.

Add properties on `NavigationService`:

```swift
private(set) var phase: NavigationPhase = .idle
private(set) var previewRoutes: [NavRouteOption] = []
private(set) var selectedRouteID: UUID?
private(set) var previewErrorMessage: String?

var selectedPreviewRoute: NavRouteOption? {
    previewRoutes.first { $0.id == selectedRouteID } ?? previewRoutes.first
}

var isPreviewing: Bool { phase == .previewing }
var isNavigating: Bool { phase == .navigating }
```

- [ ] **Step 2: Gate guidance in `updateOrigin`**

Replace the guidance block so remaining distance can update in preview for the selected polyline, but steps/voice/off-route only while navigating:

```swift
func updateOrigin(_ coordinate: CLLocationCoordinate2D) {
    origin = coordinate
    completer.region = MKCoordinateRegion(
        center: coordinate,
        latitudinalMeters: 60_000,
        longitudinalMeters: 60_000
    )
    guard hasRoute else { return }
    recomputeRemaining(from: coordinate)
    guard phase == .navigating else { return }
    advanceStepIfNeeded(from: coordinate)
    checkOffRouteAndRecalculate(from: coordinate)
}
```

- [ ] **Step 3: Replace immediate-nav `setDestination` with preview entry**

```swift
func setDestination(coordinate: CLLocationCoordinate2D, name: String, subtitle: String = "") {
    beginPreview(coordinate: coordinate, name: name, subtitle: subtitle)
}

func beginPreview(coordinate: CLLocationCoordinate2D, name: String, subtitle: String = "") {
    DestinationSearchHistory.add(
        name: name,
        subtitle: subtitle,
        latitude: coordinate.latitude,
        longitude: coordinate.longitude
    )
    destinationCoordinate = coordinate
    destinationName = name
    searchResults = []
    searchQuery = ""
    previewErrorMessage = nil
    previewRoutes = []
    selectedRouteID = nil
    steps = []
    currentStepIndex = 0
    approachedStepID = nil
    announcedStepID = nil
    voice.stop()
    isOffRoute = false
    phase = .previewing
    computeRoute(isRecalculation: false, requestAlternates: true)
}

func selectPreviewRoute(id: UUID) {
    guard phase == .previewing,
          let option = previewRoutes.first(where: { $0.id == id }) else { return }
    selectedRouteID = id
    applyPreviewSelection(option)
}

func confirmStartNavigation() {
    guard phase == .previewing, let option = selectedPreviewRoute else { return }
    phase = .navigating
    applyRoute(
        coordinates: option.coordinates,
        distance: option.distanceMeters,
        travelTime: option.expectedTravelTime,
        steps: option.steps,
        isRecalculation: false
    )
    AppLogger.navigation.notice("Navigation started with selected preview route")
}

func cancelPreview() {
    clear()
}
```

- [ ] **Step 4: Update `selectCompletion` to pass subtitle into preview**

```swift
let subtitle = [completion.subtitle].first { !$0.isEmpty } ?? ""
// after resolving item:
self.beginPreview(
    coordinate: coordinate,
    name: name,
    subtitle: completion.subtitle
)
```

- [ ] **Step 5: Update `computeRoute` / apply path for alternates**

Change signature and request:

```swift
private func computeRoute(isRecalculation: Bool, requestAlternates: Bool = false) {
    guard let origin, let destinationCoordinate else { return }
    // … existing isRouting / isRecalculating flags …

    let request = MKDirections.Request()
    request.source = MapKitPlace.mapItem(coordinate: origin)
    request.destination = MapKitPlace.mapItem(coordinate: destinationCoordinate)
    request.transportType = .automobile
    request.requestsAlternateRoutes = requestAlternates && !isRecalculation

    MKDirections(request: request).calculate { response, error in
        // … log error …
        let mkRoutes = response?.routes ?? []
        Task { @MainActor in
            if self.phase == .previewing, !isRecalculation {
                self.applyPreviewRoutes(mkRoutes)
            } else if let route = mkRoutes.first {
                // existing single-route apply for navigating recalculation
                let coordinates = route.polyline.coordinates
                let navSteps: [NavStep] = /* same compactMap as today */
                self.applyRoute(
                    coordinates: coordinates,
                    distance: route.distance,
                    travelTime: route.expectedTravelTime,
                    steps: navSteps,
                    isRecalculation: isRecalculation
                )
            } else {
                self.isRouting = false
                self.isRecalculating = false
                if self.phase == .previewing {
                    self.previewErrorMessage = "Couldn't find a driving route."
                }
            }
        }
    }
}
```

Add helpers:

```swift
private func applyPreviewRoutes(_ mkRoutes: [MKRoute]) {
    isRouting = false
    isRecalculating = false
    guard !mkRoutes.isEmpty else {
        previewRoutes = []
        selectedRouteID = nil
        routeCoordinates = []
        previewErrorMessage = "Couldn't find a driving route."
        return
    }
    previewErrorMessage = nil
    previewRoutes = mkRoutes.map { route in
        let coords = route.polyline.coordinates
        let navSteps: [NavStep] = route.steps.compactMap { step in
            let instruction = step.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty else { return nil }
            let stepCoords = step.polyline.coordinates
            let end = stepCoords.last ?? step.polyline.coordinate
            return NavStep(instruction: instruction, distance: step.distance, endCoordinate: end)
        }
        return NavRouteOption(
            id: UUID(),
            coordinates: coords,
            distanceMeters: route.distance,
            expectedTravelTime: route.expectedTravelTime,
            steps: navSteps
        )
    }
    let first = previewRoutes[0]
    selectedRouteID = first.id
    applyPreviewSelection(first)
    // Do NOT call onRouteApplied yet — weather/guidance wait until confirmStartNavigation
}

private func applyPreviewSelection(_ option: NavRouteOption) {
    routeCoordinates = option.coordinates
    totalRouteDistance = option.distanceMeters
    totalTravelTime = option.expectedTravelTime
    distanceRemaining = option.distanceMeters
    eta = option.expectedTravelTime > 0
        ? Date().addingTimeInterval(option.expectedTravelTime)
        : nil
    steps = [] // no turn list until Start
    currentStepIndex = 0
    distanceToNextManeuver = 0
}
```

Update `clear()` to also reset:

```swift
phase = .idle
previewRoutes = []
selectedRouteID = nil
previewErrorMessage = nil
```

Update off-route recalculation call site to keep `computeRoute(isRecalculation: true)` (alternates off).

- [ ] **Step 6: Build**

```bash
xcodebuild -scheme MotoTripTracker -destination 'generic/platform=iOS' build
```

Expected: **BUILD SUCCEEDED**

- [ ] **Step 7: Commit**

```bash
git add MotoTripTracker/Services/NavigationService.swift
git commit -m "$(cat <<'EOF'
feat: add navigation preview phase with alternate routes

EOF
)"
```

---

### Task 3: Destination search history UI

**Files:**
- Modify: `MotoTripTracker/UI/Tracker/DestinationSearchView.swift`

**Interfaces:**
- Consumes: `DestinationSearchHistory.all/remove`, `NavigationService.beginPreview`

- [ ] **Step 1: Rewrite list body to show Recents when query is empty**

Use `@State private var history: [DestinationHistoryEntry] = []` and reload on appear / after delete.

Structure:

```swift
List {
    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if history.isEmpty {
            Section {
                Text("Search for an address or place to set as your destination.")
                // existing styling
            }
        } else {
            Section("Recent") {
                ForEach(history) { entry in
                    Button {
                        app.navigationService.beginPreview(
                            coordinate: CLLocationCoordinate2D(
                                latitude: entry.latitude,
                                longitude: entry.longitude
                            ),
                            name: entry.name,
                            subtitle: entry.subtitle
                        )
                        dismiss()
                    } label: { /* name + subtitle rows */ }
                    .listRowBackground(colors.bgCard)
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        DestinationSearchHistory.remove(id: history[index].id)
                    }
                    history = DestinationSearchHistory.all()
                }
            }
        }
    } else if results.isEmpty {
        // "No matches yet."
    } else {
        // existing ForEach results → beginPreview via selectCompletion (already wired)
    }
}
.onAppear { history = DestinationSearchHistory.all() }
```

Ensure completer selection still dismisses after `selectCompletion` (history written inside `beginPreview`).

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme MotoTripTracker -destination 'generic/platform=iOS' build
```

Expected: **BUILD SUCCEEDED**

- [ ] **Step 3: Commit**

```bash
git add MotoTripTracker/UI/Tracker/DestinationSearchView.swift
git commit -m "$(cat <<'EOF'
feat: show deletable recent destinations in search sheet

EOF
)"
```

---

### Task 4: Map polylines for alternate routes

**Files:**
- Modify: `MotoTripTracker/UI/Tracker/LiveRideMapView.swift`

**Interfaces:**
- Consumes: `navigationService.phase`, `previewRoutes`, `selectedRouteID`, `routeCoordinates`

- [ ] **Step 1: Draw preview alternates; keep single route while navigating**

```swift
let nav = app.navigationService
let traveled = app.tripManager.routeCoordinates
let destination = nav.destinationCoordinate

Map(position: $cameraPosition) {
    UserAnnotation()

    if nav.phase == .previewing {
        ForEach(nav.previewRoutes) { option in
            let selected = option.id == nav.selectedRouteID
            MapPolyline(coordinates: option.coordinates)
                .stroke(
                    colors.neonBlue.opacity(selected ? 1 : 0.35),
                    style: StrokeStyle(
                        lineWidth: selected ? 6 : 4,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
        }
    } else if nav.routeCoordinates.count > 1 {
        MapPolyline(coordinates: nav.routeCoordinates)
            .stroke(
                colors.neonBlue,
                style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
            )
    }

    // traveled + destination pin unchanged
}
```

- [ ] **Step 2: Fit camera when preview routes appear**

Add `.onChange(of: nav.selectedRouteID)` and/or `previewRoutes.count` to set `cameraPosition` to a region covering the selected route’s bounding map rect (use `MKPolyline` / min-max lat-lon). Only auto-fit while `phase == .previewing` and not actively riding follow-camera, or fit once when preview first loads — prefer fit when `previewRoutes` becomes non-empty and when selection changes during preview.

- [ ] **Step 3: Build + commit**

```bash
xcodebuild -scheme MotoTripTracker -destination 'generic/platform=iOS' build
git add MotoTripTracker/UI/Tracker/LiveRideMapView.swift
git commit -m "$(cat <<'EOF'
feat: draw alternate preview routes on the live map

EOF
)"
```

---

### Task 5: Route preview card on RideTrackerView

**Files:**
- Modify: `MotoTripTracker/UI/Tracker/RideTrackerView.swift`

**Interfaces:**
- Consumes: `phase`, `previewRoutes`, `selectPreviewRoute`, `confirmStartNavigation`, `cancelPreview`, `isRouting`, `previewErrorMessage`

- [ ] **Step 1: Gate overlays by phase**

In the map overlay / bottom chip area:

- `phase == .idle` → existing `idleNavOverlay` (+ always-location banner as today)
- `phase == .previewing` → new `routePreviewCard(colors:)`
- `phase == .navigating` → existing `topTurnBanner` + `activeRouteChip`

Replace checks like `if app.navigationService.hasDestination` for turn UI with `isNavigating` (or `phase == .navigating`). Keep destination pin via map (still has destination in preview).

- [ ] **Step 2: Implement `routePreviewCard`**

Card contents:

- Title: `destinationName ?? "Destination"`
- If `isRouting`: `ProgressView` + “Finding routes…”
- Else if `previewErrorMessage != nil`: show message
- Else: ForEach `previewRoutes` as tappable rows/chips showing:
  - Label: index 0 → “Fastest” (or “Route 1”); others “Route 2”, …
  - `NavigationService.formatDistance(option.distanceMeters)`
  - duration: `Int((option.expectedTravelTime / 60).rounded())` + " min"
  - Selected state uses neon green / blue border
- Buttons:
  - **Start** → `confirmStartNavigation()`; disabled if no selected route or still routing / error
  - **Cancel** → `cancelPreview()`

Place the card where `activeRouteChip` / idle overlay sits (bottom of map), padded like existing chips.

- [ ] **Step 3: Build + commit**

```bash
xcodebuild -scheme MotoTripTracker -destination 'generic/platform=iOS' build
git add MotoTripTracker/UI/Tracker/RideTrackerView.swift
git commit -m "$(cat <<'EOF'
feat: add Start/Cancel route preview card on the dashboard

EOF
)"
```

---

### Task 6: Petrol Go uses preview

**Files:**
- Modify: `MotoTripTracker/UI/Tracker/PetrolStationsView.swift`
- Modify: `MotoTripTracker/Services/NavigationService.swift` (petrol `setDestination` call sites already go through preview if Task 2 wrapped `setDestination`)

- [ ] **Step 1: Confirm Petrol “Go” calls `beginPreview` / `setDestination`**

In `PetrolStationsView` Go button (today ~line 133), prefer explicit:

```swift
app.navigationService.beginPreview(
    coordinate: rec.coordinate,
    name: rec.name,
    subtitle: rec.address // or "" if unavailable
)
```

Internal `navigateToNearestPetrol` paths that call `setDestination` already enter preview if Task 2 redirected `setDestination` → `beginPreview`.

- [ ] **Step 2: Dismiss petrol sheet after Go** (keep existing `dismiss()`)

- [ ] **Step 3: Build + commit**

```bash
xcodebuild -scheme MotoTripTracker -destination 'generic/platform=iOS' build
git add MotoTripTracker/UI/Tracker/PetrolStationsView.swift MotoTripTracker/Services/NavigationService.swift
git commit -m "$(cat <<'EOF'
feat: route petrol Go through navigation preview

EOF
)"
```

---

### Task 7: Docs + manual verification

**Files:**
- Modify: `README.md` (navigation bullets)

- [ ] **Step 1: Update README navigation section**

Replace/add bullets roughly:

- Destination pick shows **alternate routes** on the map; **Start** begins turn-by-turn; **Cancel** clears preview
- Destination search keeps **Recent** history (swipe to delete)

- [ ] **Step 2: Manual test checklist** (on device)

1. Search → pick place → multiple routes (when MapKit returns them) → switch route → Start → turn banner/voice  
2. Cancel preview → idle, no guidance  
3. Recents appear; swipe delete; tap recent → preview  
4. Petrol Go → preview → Start  
5. While previewing, no spoken turns / off-route recalc  
6. After Start, off-route still recalculates  

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs: document route preview and destination history

EOF
)"
```

---

## Spec coverage (self-review)

| Spec requirement | Task |
| --- | --- |
| Multiple alternate routes via MKDirections | Task 2 |
| Preview on main map + Start/Cancel | Tasks 4–5 |
| History on select, cap 20, swipe delete | Tasks 1, 3 |
| Petrol same pipeline | Task 6 |
| No guidance while previewing | Task 2 (`updateOrigin` gate) |
| Errors when no routes | Task 2 + Task 5 card |
| README | Task 7 |

No TBD placeholders. Method names are consistent: `beginPreview`, `selectPreviewRoute`, `confirmStartNavigation`, `cancelPreview`, `NavigationPhase`, `NavRouteOption`.
