import CoreLocation
import Foundation
import Testing
@testable import MotoTripTracker

@MainActor
final class FakeTripStore: TripPersisting {
    private(set) var startedIDs: [UUID] = []
    private(set) var pointCount = 0
    private(set) var lastPointTripID: UUID?
    private(set) var flushCount = 0
    private(set) var savedIDs: [UUID] = []
    private(set) var deletedIDs: [UUID] = []
    var nextID = UUID()

    func startNewTrip(startTime: TimeInterval) -> UUID {
        startedIDs.append(nextID)
        return nextID
    }

    func addRoutePointAndUpdateStats(
        tripID: UUID,
        latitude: Double,
        longitude: Double,
        altitude: Double,
        speedMps: Double,
        time: TimeInterval,
        runningStats: TripStats
    ) {
        pointCount += 1
        lastPointTripID = tripID
    }

    func flushPendingRoutePoints() {
        flushCount += 1
    }

    func saveTrip(tripID: UUID, finalStats: TripStats, endTime: TimeInterval) {
        savedIDs.append(tripID)
    }

    func deleteTrip(id: UUID) {
        deletedIDs.append(id)
    }
}

@MainActor
struct TripManagerTests {
    @Test func startTripPersistsANewTripAndMarksSessionActive() {
        let store = FakeTripStore()
        let manager = TripManager(repository: store)
        manager.startTrip()
        #expect(store.startedIDs.count == 1)
        #expect(manager.sessionState.isActive)
        #expect(!manager.sessionState.isPaused)
    }

    @Test func rejectsInaccurateFixWithoutPersistingAPoint() {
        let store = FakeTripStore()
        let manager = TripManager(repository: store)
        manager.startTrip()
        manager.onLocationUpdate(fix(accuracy: 40, speed: 10, time: 1_000_000))
        #expect(store.pointCount == 0)
        #expect(manager.sessionState.isActive)
    }

    @Test func validMovingFixesPersistPointsAndGrowDistance() {
        let store = FakeTripStore()
        let manager = TripManager(repository: store)
        manager.startTrip()
        manager.onLocationUpdate(fix(latitude: 37.98000, longitude: 23.7200, speed: 12, time: 1_000_000))
        manager.onLocationUpdate(fix(latitude: 37.98070, longitude: 23.7200, speed: 12, time: 1_000_006))
        #expect(store.pointCount == 2)
        #expect(store.lastPointTripID == store.startedIDs.first)
        #expect(manager.sessionState.stats.distanceMeters > 50)
        #expect(manager.routeCoordinates.count == 2)
    }

    @Test func pauseFlushesPendingPointsAndIgnoresFurtherFixes() {
        let store = FakeTripStore()
        let manager = TripManager(repository: store)
        manager.startTrip()
        manager.onLocationUpdate(fix(latitude: 37.9800, longitude: 23.7200, speed: 12, time: 1_000_000))
        manager.pauseTrip()
        #expect(manager.sessionState.isPaused)
        #expect(store.flushCount == 1)
        manager.onLocationUpdate(fix(latitude: 37.9810, longitude: 23.7200, speed: 12, time: 1_000_001))
        #expect(store.pointCount == 1)
    }

    @Test func stopBelowMinimumDistanceDeletesTheTrip() {
        let store = FakeTripStore()
        let manager = TripManager(repository: store)
        manager.startTrip()
        let saved = manager.stopTrip()
        #expect(!saved)
        #expect(store.deletedIDs == store.startedIDs)
        #expect(store.savedIDs.isEmpty)
        #expect(!manager.sessionState.isActive)
    }

    @Test func stopAboveMinimumDistanceSavesTheTrip() {
        let store = FakeTripStore()
        let manager = TripManager(repository: store)
        manager.startTrip()
        manager.onLocationUpdate(fix(latitude: 37.98000, longitude: 23.7200, speed: 12, time: 1_000_000))
        manager.onLocationUpdate(fix(latitude: 37.98070, longitude: 23.7200, speed: 12, time: 1_000_006))
        let saved = manager.stopTrip()
        #expect(saved)
        #expect(store.savedIDs == store.startedIDs)
        #expect(store.deletedIDs.isEmpty)
        #expect(!manager.sessionState.isActive)
    }

    private func fix(
        latitude: Double = 37.98,
        longitude: Double = 23.72,
        accuracy: Double = 8,
        speed: Double = 10,
        time: TimeInterval
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 100,
            horizontalAccuracy: accuracy,
            verticalAccuracy: 5,
            course: 0,
            speed: speed,
            timestamp: Date(timeIntervalSince1970: time)
        )
    }
}
