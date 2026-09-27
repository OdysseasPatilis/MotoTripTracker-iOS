import CoreLocation
import Foundation
import Testing
@testable import MotoTripTracker

struct SpeedLimitHoldTests {
    @Test func firstLimitIsShownImmediately() {
        var hold = SpeedLimitHold()
        let shown = hold.consider(90, at: location(latitude: 37.98, speedMps: 20))
        #expect(shown == 90)
    }

    @Test func briefDifferentCellDoesNotReplaceLimit() {
        var hold = SpeedLimitHold()
        let start = location(latitude: 37.9800, speedMps: 10, at: t0)
        #expect(hold.consider(90, at: start) == 90)

        let drifted = offset(start, metersNorth: 15, after: 2, speedMps: 10)
        #expect(hold.consider(40, at: drifted) == 90)
    }

    @Test func sustainedTravelOnNewLimitReplacesIt() {
        var hold = SpeedLimitHold()
        let start = location(latitude: 37.9800, speedMps: 10, at: t0)
        _ = hold.consider(90, at: start)

        let entered = offset(start, metersNorth: 30, after: 1, speedMps: 10)
        #expect(hold.consider(40, at: entered) == 90)

        let alongNewStreet = offset(entered, metersNorth: 100, after: 7, speedMps: 10)
        #expect(hold.consider(40, at: alongNewStreet) == 40)
    }

    @Test func returningToPreviousLimitCancelsThePendingChange() {
        var hold = SpeedLimitHold()
        let start = location(latitude: 37.9800, speedMps: 10, at: t0)
        _ = hold.consider(90, at: start)
        let drifted = offset(start, metersNorth: 20, after: 1, speedMps: 10)
        _ = hold.consider(40, at: drifted)

        let back = offset(start, metersNorth: 5, after: 3, speedMps: 10)
        #expect(hold.consider(90, at: back) == 90)

        // A new 40 spell has to earn its own dwell; the earlier spell does not carry over.
        let again = offset(back, metersNorth: 100, after: 4, speedMps: 10)
        #expect(hold.consider(40, at: again) == 90)
    }

    @Test func lowerLimitIsHeldWhileStillClearlyFasterThanIt() {
        var hold = SpeedLimitHold()
        let start = location(latitude: 37.9800, speedMps: 25, at: t0) // 90 km/h
        _ = hold.consider(90, at: start)

        let sideStreet = offset(start, metersNorth: 30, after: 1, speedMps: 25)
        #expect(hold.consider(40, at: sideStreet) == 90)

        let stillFast = offset(sideStreet, metersNorth: 100, after: 8, speedMps: 25)
        #expect(hold.consider(40, at: stillFast) == 90)

        let slowed = offset(stillFast, metersNorth: 10, after: 1, speedMps: 10) // 36 km/h
        #expect(hold.consider(40, at: slowed) == 40)
    }
}

struct SpeedLimitServiceStabilityTests {
    @Test @MainActor func packCellFlickerDoesNotChangeTheDisplayedLimit() {
        let defaults = UserDefaults(suiteName: "SpeedLimitServiceStabilityTests")!
        defaults.removePersistentDomain(forName: "SpeedLimitServiceStabilityTests")
        let pack = SpeedLimitRegionPack(
            id: "test",
            name: "Test",
            version: 1,
            gridScale: 500,
            south: 37,
            west: 23,
            north: 39,
            east: 25,
            cells: ["18991_11863": 90, "18992_11863": 40]
        )
        let service = SpeedLimitService(
            cacheStore: SpeedLimitCacheStore(defaults: defaults),
            regionPacks: [pack]
        )

        // 37.9838 → cell 18991 (90). 37.985 → cell 18992 (40). 10 m/s keeps both plausible.
        service.refresh(for: location(latitude: 37.9838, longitude: 23.7275, speedMps: 10, at: t0))
        #expect(service.effectiveLimitKmh == 90)

        service.refresh(for: location(latitude: 37.9850, longitude: 23.7275, speedMps: 10, at: t0.addingTimeInterval(2)))
        #expect(service.effectiveLimitKmh == 90)
    }
}

struct OffRouteGateTests {
    @Test func singleSpikeDoesNotRecalculate() {
        var gate = OffRouteGate()
        let decision = gate.shouldRecalculate(
            crossTrack: 120,
            horizontalAccuracy: 8,
            course: 90,
            routeBearing: 0,
            speedMps: 12,
            location: location(latitude: 37.98, speedMps: 12, course: 90, at: t0)
        )
        #expect(!decision)
    }

    @Test func travelingOffWithADifferentHeadingRecalculates() {
        var gate = OffRouteGate()
        let first = gate.shouldRecalculate(
            crossTrack: 60,
            horizontalAccuracy: 8,
            course: 90,
            routeBearing: 0,
            speedMps: 12,
            location: location(latitude: 37.9800, speedMps: 12, course: 90, at: t0)
        )
        let second = gate.shouldRecalculate(
            crossTrack: 70,
            horizontalAccuracy: 8,
            course: 90,
            routeBearing: 0,
            speedMps: 12,
            location: location(latitude: 37.9803, speedMps: 12, course: 90, at: t0.addingTimeInterval(2))
        )
        let third = gate.shouldRecalculate(
            crossTrack: 80,
            horizontalAccuracy: 8,
            course: 90,
            routeBearing: 0,
            speedMps: 12,
            location: location(latitude: 37.9806, speedMps: 12, course: 90, at: t0.addingTimeInterval(4))
        )
        #expect(!first)
        #expect(!second)
        #expect(third)
    }

    @Test func sameHeadingLateralJitterDoesNotRecalculate() {
        var gate = OffRouteGate()
        var committed = false
        for step in 0..<6 {
            let decision = gate.shouldRecalculate(
                crossTrack: 25,
                horizontalAccuracy: 8,
                course: 5,
                routeBearing: 0,
                speedMps: 15,
                location: location(
                    latitude: 37.9800 + Double(step) * 0.0004,
                    speedMps: 15,
                    course: 5,
                    at: t0.addingTimeInterval(Double(step))
                )
            )
            committed = committed || decision
        }
        #expect(!committed)
    }

    @Test func stoppedDriftDoesNotRecalculate() {
        var gate = OffRouteGate()
        let parked = location(latitude: 37.98, speedMps: 0, course: 90, at: t0)
        var committed = false
        for step in 0..<8 {
            let decision = gate.shouldRecalculate(
                crossTrack: 100,
                horizontalAccuracy: 8,
                course: 90,
                routeBearing: 0,
                speedMps: 0,
                location: CLLocation(
                    coordinate: parked.coordinate,
                    altitude: 0,
                    horizontalAccuracy: 8,
                    verticalAccuracy: 5,
                    course: 90,
                    speed: 0,
                    timestamp: t0.addingTimeInterval(Double(step))
                )
            )
            committed = committed || decision
        }
        #expect(!committed)
    }

    @Test func returningToTheRouteCancelsThePendingDeparture() {
        var gate = OffRouteGate()
        _ = gate.shouldRecalculate(
            crossTrack: 80,
            horizontalAccuracy: 8,
            course: 90,
            routeBearing: 0,
            speedMps: 12,
            location: location(latitude: 37.9800, speedMps: 12, course: 90, at: t0)
        )
        _ = gate.shouldRecalculate(
            crossTrack: 5,
            horizontalAccuracy: 8,
            course: 0,
            routeBearing: 0,
            speedMps: 12,
            location: location(latitude: 37.9802, speedMps: 12, course: 0, at: t0.addingTimeInterval(2))
        )
        let restarted = gate.shouldRecalculate(
            crossTrack: 80,
            horizontalAccuracy: 8,
            course: 90,
            routeBearing: 0,
            speedMps: 12,
            location: location(latitude: 37.9804, speedMps: 12, course: 90, at: t0.addingTimeInterval(4))
        )
        #expect(!restarted)
    }
}

struct RouteMatchWindowTests {
    @Test func nearbyLaterVertexDoesNotStealTheMatch() {
        var route = [CLLocationCoordinate2D(latitude: 37.98000, longitude: 23.72000)]
        // ~222 m steps north, well past the forward search window, then a vertex beside the start.
        for step in 1...16 {
            route.append(
                CLLocationCoordinate2D(
                    latitude: 37.98000 + Double(step) * 0.002,
                    longitude: 23.72000
                )
            )
        }
        route.append(CLLocationCoordinate2D(latitude: 37.98018, longitude: 23.72000))

        let here = CLLocationCoordinate2D(latitude: 37.98016, longitude: 23.72000)
        let progress = NavigationRouteMath.progress(at: here, on: route, nearIndex: 0)
        #expect(progress.nearestIndex == 0)
        #expect(progress.nearestDistance < 30)
    }
}

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func location(
    latitude: Double,
    longitude: Double = 23.72,
    speedMps: Double,
    course: CLLocationDirection = 0,
    at date: Date = t0
) -> CLLocation {
    CLLocation(
        coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
        altitude: 0,
        horizontalAccuracy: 5,
        verticalAccuracy: 5,
        course: course,
        speed: speedMps,
        timestamp: date
    )
}

private func offset(
    _ origin: CLLocation,
    metersNorth: Double,
    after seconds: TimeInterval,
    speedMps: Double
) -> CLLocation {
    location(
        latitude: origin.coordinate.latitude + metersNorth / 111_320,
        longitude: origin.coordinate.longitude,
        speedMps: speedMps,
        at: origin.timestamp.addingTimeInterval(seconds)
    )
}
