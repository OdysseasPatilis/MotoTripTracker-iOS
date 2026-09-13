# Riding Camera Look-Ahead, Turn Zoom & Larger Turn HUD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While recording with follow on, put more road ahead on the map, zoom in for approaching turns using a speed-scaled window, and enlarge the top turn banner so instructions are glanceable.

**Architecture:** Extract pure camera math into `RideFollowCameraPolicy` (look-ahead offset + cruise/approach distances). `LiveRideMapView.updateCamera` calls it with speed, course, nav distance, and guiding flag. `RideTrackerView.topTurnBanner` gets larger typography/padding only—no new HUD screens.

**Tech Stack:** Swift / SwiftUI / MapKit (`MapCamera`), CoreLocation, Swift Testing (`MotoTripTrackerTests`)

## Global Constraints

- Scope: camera math in follow path + enlarge existing turn banner only
- Look-ahead: speed-scaled; stronger when navigating
- Turn zoom: speed-scaled approach window; skip aggressive zoom while recalculating
- Apply only when `isRiding` + `isFollowingUser`; idle top-down unchanged
- No polyline look-ahead; no new camera service type beyond the policy helper
- Voice prompt distances unchanged
- Prefer local named constants on the policy type

---

## File map

| File | Responsibility |
| --- | --- |
| `MotoTripTracker/Utilities/RideFollowCameraPolicy.swift` | Pure look-ahead + distance policy |
| `MotoTripTracker/UI/Tracker/LiveRideMapView.swift` | Wire policy into `updateCamera` |
| `MotoTripTracker/UI/Tracker/RideTrackerView.swift` | Larger `topTurnBanner` |
| `MotoTripTrackerTests/MotoTripTrackerTests.swift` | Unit tests for policy math |
| `README.md` | One-line note on riding camera / larger turn HUD |

---

### Task 1: `RideFollowCameraPolicy` (pure math + tests)

**Files:**
- Create: `MotoTripTracker/Utilities/RideFollowCameraPolicy.swift`
- Test: `MotoTripTrackerTests/MotoTripTrackerTests.swift`

**Interfaces:**
- Produces:
  - `enum RideFollowCameraPolicy` with:
    - `static func lookAheadMeters(speedKmh: Double, isNavigating: Bool) -> CLLocationDistance`
    - `static func coordinateAhead(of coordinate: CLLocationCoordinate2D, courseDegrees: CLLocationDirection, meters: CLLocationDistance) -> CLLocationCoordinate2D`
    - `static func approachWindowMeters(speedKmh: Double) -> CLLocationDistance`
    - `static func cruiseDistanceMeters(speedKmh: Double) -> CLLocationDistance`
    - `static func cameraDistanceMeters(speedKmh: Double, distanceToNextManeuver: CLLocationDistance?, isNavigating: Bool, isRecalculating: Bool) -> CLLocationDistance`
    - `static func centerCoordinate(rider: CLLocationCoordinate2D, courseDegrees: CLLocationDirection, speedKmh: Double, isNavigating: Bool) -> CLLocationCoordinate2D`
  - Constants (approx from spec):
    - Cruise: `350 + min(speedKmh, 180) * 7` (preserve today’s curve)
    - Look-ahead: ~40 m at 20 km/h → ~180 m at 100 km/h; +20% when navigating
    - Approach window: ~135 m @ 40, ~250 m @ 80, ~375 m @ 120 (linear in speed, clamped)
    - Approach closest distance: ~55% of cruise (clamped floor ~220 m)

- [ ] **Step 1: Write failing tests**

Append to `MotoTripTrackerTests/MotoTripTrackerTests.swift`:

```swift
@Test func rideFollowCameraCruiseDistanceMatchesBaseline() {
    #expect(RideFollowCameraPolicy.cruiseDistanceMeters(speedKmh: 0) == 350)
    #expect(RideFollowCameraPolicy.cruiseDistanceMeters(speedKmh: 100) == 350 + 700)
    #expect(RideFollowCameraPolicy.cruiseDistanceMeters(speedKmh: 200) == 350 + 180 * 7)
}

@Test func rideFollowCameraLookAheadGrowsWithSpeedAndNav() {
    let slow = RideFollowCameraPolicy.lookAheadMeters(speedKmh: 20, isNavigating: false)
    let fast = RideFollowCameraPolicy.lookAheadMeters(speedKmh: 100, isNavigating: false)
    let fastNav = RideFollowCameraPolicy.lookAheadMeters(speedKmh: 100, isNavigating: true)
    #expect(fast > slow)
    #expect(fastNav > fast)
}

@Test func rideFollowCameraCenterUsesCourseWhenValid() {
    let rider = CLLocationCoordinate2D(latitude: 37.98, longitude: 23.72)
    let ahead = RideFollowCameraPolicy.centerCoordinate(
        rider: rider,
        courseDegrees: 0,
        speedKmh: 80,
        isNavigating: true
    )
    #expect(ahead.latitude > rider.latitude)
    #expect(abs(ahead.longitude - rider.longitude) < 0.001)

    let noCourse = RideFollowCameraPolicy.centerCoordinate(
        rider: rider,
        courseDegrees: -1,
        speedKmh: 80,
        isNavigating: true
    )
    #expect(noCourse.latitude == rider.latitude)
    #expect(noCourse.longitude == rider.longitude)
}

@Test func rideFollowCameraZoomsNearTurnWhenNavigating() {
    let cruise = RideFollowCameraPolicy.cameraDistanceMeters(
        speedKmh: 80,
        distanceToNextManeuver: 2000,
        isNavigating: true,
        isRecalculating: false
    )
    let near = RideFollowCameraPolicy.cameraDistanceMeters(
        speedKmh: 80,
        distanceToNextManeuver: 80,
        isNavigating: true,
        isRecalculating: false
    )
    #expect(near < cruise)

    let recalculating = RideFollowCameraPolicy.cameraDistanceMeters(
        speedKmh: 80,
        distanceToNextManeuver: 80,
        isNavigating: true,
        isRecalculating: true
    )
    #expect(recalculating == cruise)
}

@Test func rideFollowCameraApproachWindowScalesWithSpeed() {
    let city = RideFollowCameraPolicy.approachWindowMeters(speedKmh: 40)
    let mid = RideFollowCameraPolicy.approachWindowMeters(speedKmh: 80)
    let hwy = RideFollowCameraPolicy.approachWindowMeters(speedKmh: 120)
    #expect(city >= 120 && city <= 150)
    #expect(abs(mid - 250) < 15)
    #expect(hwy >= 350 && hwy <= 400)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -scheme MotoTripTracker -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:MotoTripTrackerTests/MotoTripTrackerTests/rideFollowCameraCruiseDistanceMatchesBaseline 2>&1 | tail -30
```

Expected: FAIL / compile error — `RideFollowCameraPolicy` not found.

If simulator name differs, list devices with `xcrun simctl list devices available` and pick an iPhone.

- [ ] **Step 3: Implement `RideFollowCameraPolicy`**

Create `MotoTripTracker/Utilities/RideFollowCameraPolicy.swift`:

```swift
import CoreLocation
import Foundation

/// Pure camera framing for ride-follow: look-ahead center + cruise / turn-approach distance.
nonisolated enum RideFollowCameraPolicy {
    /// Preserve today’s riding pull-back curve.
    static func cruiseDistanceMeters(speedKmh: Double) -> CLLocationDistance {
        350.0 + min(max(speedKmh, 0), 180) * 7.0
    }

    /// Meters ahead of the rider for map center (speed-scaled; +20% when navigating).
    static func lookAheadMeters(speedKmh: Double, isNavigating: Bool) -> CLLocationDistance {
        let speed = max(speedKmh, 0)
        // ~40 m @ 20 km/h → ~180 m @ 100 km/h
        let base = 10.0 + min(speed, 160) * 1.7
        return isNavigating ? base * 1.2 : base
    }

    /// Distance-to-maneuver at which turn zoom begins.
    static func approachWindowMeters(speedKmh: Double) -> CLLocationDistance {
        let speed = min(max(speedKmh, 0), 160)
        // 40→135, 80→250, 120→375
        let window = 20.0 + speed * 2.95
        return min(max(window, 120), 400)
    }

    static func cameraDistanceMeters(
        speedKmh: Double,
        distanceToNextManeuver: CLLocationDistance?,
        isNavigating: Bool,
        isRecalculating: Bool
    ) -> CLLocationDistance {
        let cruise = cruiseDistanceMeters(speedKmh: speedKmh)
        guard isNavigating,
              !isRecalculating,
              let toTurn = distanceToNextManeuver,
              toTurn >= 0 else {
            return cruise
        }
        let window = approachWindowMeters(speedKmh: speedKmh)
        guard toTurn <= window else { return cruise }

        let closest = max(cruise * 0.55, 220)
        let progress = 1.0 - (toTurn / window) // 0 at window edge, 1 at turn
        let t = min(max(progress, 0), 1)
        return cruise + (closest - cruise) * t
    }

    static func centerCoordinate(
        rider: CLLocationCoordinate2D,
        courseDegrees: CLLocationDirection,
        speedKmh: Double,
        isNavigating: Bool
    ) -> CLLocationCoordinate2D {
        guard courseDegrees >= 0 else { return rider }
        let meters = lookAheadMeters(speedKmh: speedKmh, isNavigating: isNavigating)
        return coordinateAhead(of: rider, courseDegrees: courseDegrees, meters: meters)
    }

    static func coordinateAhead(
        of coordinate: CLLocationCoordinate2D,
        courseDegrees: CLLocationDirection,
        meters: CLLocationDistance
    ) -> CLLocationCoordinate2D {
        guard meters > 0 else { return coordinate }
        let earthRadius = 6_371_000.0
        let bearing = courseDegrees * .pi / 180
        let lat1 = coordinate.latitude * .pi / 180
        let lon1 = coordinate.longitude * .pi / 180
        let angular = meters / earthRadius

        let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(bearing))
        let lon2 = lon1 + atan2(
            sin(bearing) * sin(angular) * cos(lat1),
            cos(angular) - sin(lat1) * sin(lat2)
        )

        return CLLocationCoordinate2D(
            latitude: lat2 * 180 / .pi,
            longitude: lon2 * 180 / .pi
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```bash
xcodebuild test -scheme MotoTripTracker -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:MotoTripTrackerTests 2>&1 | rg -i 'Test Case|passed|failed|error:|TEST SUCCEEDED|TEST FAILED' | tail -40
```

Expected: all `rideFollowCamera*` tests PASS; suite green (or only pre-existing failures unrelated).

- [ ] **Step 5: Commit**

```bash
git add MotoTripTracker/Utilities/RideFollowCameraPolicy.swift MotoTripTrackerTests/MotoTripTrackerTests.swift
git commit -m "$(cat <<'EOF'
feat: add ride-follow camera look-ahead and turn-zoom policy

EOF
)"
```

---

### Task 2: Wire policy into `LiveRideMapView.updateCamera`

**Files:**
- Modify: `MotoTripTracker/UI/Tracker/LiveRideMapView.swift` (`updateCamera`)

**Interfaces:**
- Consumes: `RideFollowCameraPolicy.centerCoordinate`, `RideFollowCameraPolicy.cameraDistanceMeters`
- Uses: `app.navigationService.isNavigating`, `distanceToNextManeuver`, `isRecalculating`, `location.course`, `location.speed`

- [ ] **Step 1: Replace riding branch of `updateCamera`**

In `LiveRideMapView.swift`, change the riding branch inside `updateCamera` to:

```swift
if isRiding {
    let speedKmh = max(location.speed, 0) * 3.6
    let navigation = app.navigationService
    let isNavigating = navigation.isNavigating
    let heading = location.course >= 0 ? location.course : 0
    let center = RideFollowCameraPolicy.centerCoordinate(
        rider: location.coordinate,
        courseDegrees: location.course,
        speedKmh: speedKmh,
        isNavigating: isNavigating
    )
    let distance = RideFollowCameraPolicy.cameraDistanceMeters(
        speedKmh: speedKmh,
        distanceToNextManeuver: isNavigating ? navigation.distanceToNextManeuver : nil,
        isNavigating: isNavigating,
        isRecalculating: navigation.isRecalculating
    )
    camera = MapCamera(
        centerCoordinate: center,
        distance: distance,
        heading: heading,
        pitch: 55
    )
} else {
    // unchanged idle camera
    camera = MapCamera(
        centerCoordinate: location.coordinate,
        distance: 1400,
        heading: 0,
        pitch: 0
    )
}
```

Keep existing guards (`previewing`, `isFollowingUser`, `location`), animation, and `programmaticCameraTokens`.

Update the file header comment to mention look-ahead + turn approach zoom.

- [ ] **Step 2: Build**

Run:

```bash
xcodebuild -scheme MotoTripTracker -destination 'generic/platform=iOS' build 2>&1 | rg -i 'error:|BUILD SUCCEEDED|BUILD FAILED' | head -20
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add MotoTripTracker/UI/Tracker/LiveRideMapView.swift
git commit -m "$(cat <<'EOF'
feat: apply look-ahead and turn-zoom camera while riding

EOF
)"
```

---

### Task 3: Enlarge `topTurnBanner`

**Files:**
- Modify: `MotoTripTracker/UI/Tracker/RideTrackerView.swift` (`topTurnBanner` ~403–446)

**Interfaces:**
- No new types; layout-only change to existing banner

- [ ] **Step 1: Update banner layout**

Replace `topTurnBanner` body sizing as follows (keep same structure / accents / states):

```swift
private func topTurnBanner(colors: AppPalette) -> some View {
    let nav = app.navigationService
    let accent = (nav.isOffRoute || nav.isRecalculating) ? colors.routeAmber : colors.neonBlue
    return HStack(spacing: 14) {
        Image(systemName: maneuverSymbol(for: nav))
            .font(.title.weight(.bold))
            .foregroundStyle(colors.bgDeep)
            .frame(width: 56, height: 56)
            .background(accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

        VStack(alignment: .leading, spacing: 4) {
            if nav.isRecalculating {
                Text("Recalculating…")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(colors.textPrimary)
            } else if nav.isOffRoute {
                Text("Off route")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(colors.textPrimary)
            } else if let step = nav.currentStep {
                Text(NavigationService.formatDistance(nav.distanceToNextManeuver))
                    .font(.title.weight(.bold))
                    .foregroundStyle(colors.textPrimary)
                Text(step.instruction)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(colors.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if nav.isRouting {
                Text("Calculating route…")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(colors.textPrimary)
            } else {
                Text(nav.destinationName ?? "Destination")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(colors.textPrimary)
                    .lineLimit(2)
            }
        }
        Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
}
```

- [ ] **Step 2: Build**

Run:

```bash
xcodebuild -scheme MotoTripTracker -destination 'generic/platform=iOS' build 2>&1 | rg -i 'error:|BUILD SUCCEEDED|BUILD FAILED' | head -20
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add MotoTripTracker/UI/Tracker/RideTrackerView.swift
git commit -m "$(cat <<'EOF'
feat: enlarge turn banner for glanceable nav instructions

EOF
)"
```

---

### Task 4: README note + manual verify

**Files:**
- Modify: `README.md` (features list near navigation / map bullets)

- [ ] **Step 1: Document behavior**

Add a short bullet near spoken turns / map features:

```markdown
- **Riding camera:** While recording with follow on, the map centers ahead of you (more road ahead) and zooms in for upcoming turns using a speed-scaled window; the top turn banner uses larger type and a 2-line instruction
```

- [ ] **Step 2: Manual checklist** (device or simulator with location)

1. Start recording + follow: rider lower on screen vs before.  
2. Higher speed → stronger look-ahead.  
3. Navigate toward a turn: zoom tightens inside approach window; eases out after advance.  
4. Recalculating: no aggressive junction zoom.  
5. Pan → Recenter restores policy.  
6. Idle (not recording): top-down centered unchanged.  
7. Turn banner: larger icon/distance; instruction wraps to 2 lines.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs: note riding look-ahead camera and larger turn HUD

EOF
)"
```

---

## Spec coverage check

| Spec requirement | Task |
| --- | --- |
| Speed-scaled look-ahead | Task 1 + 2 |
| Stronger when navigating | Task 1 (`+20%`) + 2 |
| Speed-scaled turn zoom | Task 1 + 2 |
| Skip zoom while recalculating | Task 1 + 2 |
| Invalid course → no offset | Task 1 + 2 |
| Idle top-down unchanged | Task 2 (else branch) |
| Larger banner icon / distance / 2-line instruction | Task 3 |
| Named tunable constants | Task 1 (policy methods) |
| Manual test cases | Task 4 |

## Execution handoff

Plan complete. Prefer **subagent-driven-development** (fresh agent per task + review) or **executing-plans** (inline batches with checkpoints).
