import Foundation
import SwiftData
import Testing
@testable import MotoTripTracker

struct TripWriteActorTests {
    private let t0: TimeInterval = 1_000_000

    @Test func fiveClosePointsBecomeVisibleOnASecondContext() async throws {
        let container = try makeContainer()
        let writer = TripWriteActor(modelContainer: container)
        let tripID = UUID()
        await writer.createTrip(id: tripID, startTime: t0)

        for index in 0..<4 {
            await writer.addRoutePointAndUpdateStats(
                tripID: tripID,
                latitude: 37.98,
                longitude: 23.72,
                altitude: 100,
                speedMps: 12,
                time: t0 + Double(index) * 0.8,
                runningStats: TripStats(distanceMeters: Double(index + 1) * 10)
            )
        }
        #expect(persistedPointCount(in: container, tripID: tripID) == 0)

        await writer.addRoutePointAndUpdateStats(
            tripID: tripID,
            latitude: 37.98,
            longitude: 23.72,
            altitude: 100,
            speedMps: 12,
            time: t0 + 3.2,
            runningStats: TripStats(distanceMeters: 50)
        )
        #expect(persistedPointCount(in: container, tripID: tripID) == 5)
    }

    @Test func flushMakesPendingPointsVisibleOnASecondContext() async throws {
        let container = try makeContainer()
        let writer = TripWriteActor(modelContainer: container)
        let tripID = UUID()
        await writer.createTrip(id: tripID, startTime: t0)
        await writer.addRoutePointAndUpdateStats(
            tripID: tripID,
            latitude: 37.98,
            longitude: 23.72,
            altitude: 100,
            speedMps: 12,
            time: t0,
            runningStats: TripStats(distanceMeters: 10)
        )
        #expect(persistedPointCount(in: container, tripID: tripID) == 0)

        await writer.flushPendingRoutePoints()
        #expect(persistedPointCount(in: container, tripID: tripID) == 1)
    }

    @Test func renameIsVisibleOnASecondContext() async throws {
        let container = try makeContainer()
        let writer = TripWriteActor(modelContainer: container)
        let tripID = UUID()
        await writer.createTrip(id: tripID, startTime: t0)
        await writer.renameTrip(id: tripID, title: " Coastal loop ")

        let trip = persistedTrip(in: container, tripID: tripID)
        #expect(trip?.title == "Coastal loop")
    }

    @Test func favoriteToggleIsVisibleOnASecondContext() async throws {
        let container = try makeContainer()
        let writer = TripWriteActor(modelContainer: container)
        let tripID = UUID()
        await writer.createTrip(id: tripID, startTime: t0)
        await writer.toggleFavorite(id: tripID)

        #expect(persistedTrip(in: container, tripID: tripID)?.isFavorite == true)
    }

    @Test func recoverRemovesOpenTripsFromASecondContext() async throws {
        let container = try makeContainer()
        let writer = TripWriteActor(modelContainer: container)
        let tripID = UUID()
        await writer.createTrip(id: tripID, startTime: t0)
        #expect(persistedTrip(in: container, tripID: tripID) != nil)

        await writer.recoverOrphanedTrips()
        #expect(persistedTrip(in: container, tripID: tripID) == nil)
    }

    @Test func repairUpdatesTimingOnASecondContext() async throws {
        let container = try makeContainer()
        let writer = TripWriteActor(modelContainer: container)
        let tripID = UUID()
        await writer.createTrip(id: tripID, startTime: t0)
        await writer.addRoutePointAndUpdateStats(
            tripID: tripID,
            latitude: 37.98,
            longitude: 23.72,
            altitude: 100,
            speedMps: 12,
            time: t0,
            runningStats: TripStats(distanceMeters: 10)
        )
        await writer.addRoutePointAndUpdateStats(
            tripID: tripID,
            latitude: 37.981,
            longitude: 23.72,
            altitude: 100,
            speedMps: 12,
            time: t0 + 60,
            runningStats: TripStats(distanceMeters: 100, movingTime: 0)
        )
        await writer.flushPendingRoutePoints()
        await writer.saveTrip(
            tripID: tripID,
            finalStats: TripStats(distanceMeters: 100, movingTime: 0, maxSpeed: 40),
            endTime: t0 + 60
        )

        #expect(persistedTrip(in: container, tripID: tripID)?.movingTime == 0)
        await writer.repairUndercountedTripTimings()
        let repaired = persistedTrip(in: container, tripID: tripID)
        #expect((repaired?.movingTime ?? 0) >= 30)
    }

    @Test func waypointMarksAreVisibleOnASecondContext() async throws {
        let container = try makeContainer()
        let writer = TripWriteActor(modelContainer: container)
        let tripID = UUID()
        await writer.createTrip(id: tripID, startTime: t0)
        await writer.addRoutePointAndUpdateStats(
            tripID: tripID,
            latitude: 37.98,
            longitude: 23.72,
            altitude: 100,
            speedMps: 12,
            time: t0,
            runningStats: TripStats(distanceMeters: 10)
        )
        await writer.addRoutePointAndUpdateStats(
            tripID: tripID,
            latitude: 37.99,
            longitude: 23.73,
            altitude: 140,
            speedMps: 18,
            time: t0 + 30,
            runningStats: TripStats(distanceMeters: 80)
        )
        await writer.flushPendingRoutePoints()
        await writer.analyzeAndSaveWaypoints(
            tripID: tripID,
            totalDistanceMeters: 80,
            geocodeAddresses: false
        )

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<RoutePoint>(
            predicate: #Predicate { point in
                point.trip?.id == tripID
            }
        )
        let points = (try? context.fetch(descriptor)) ?? []
        #expect(points.contains(where: { $0.waypointType == "START" }))
        #expect(points.contains(where: { $0.waypointType == "END" }))
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Trip.self, RoutePoint.self])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    private func persistedPointCount(in container: ModelContainer, tripID: UUID) -> Int {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<RoutePoint>(
            predicate: #Predicate { point in
                point.trip?.id == tripID
            }
        )
        return (try? context.fetch(descriptor).count) ?? 0
    }

    private func persistedTrip(in container: ModelContainer, tripID: UUID) -> Trip? {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Trip>(
            predicate: #Predicate { $0.id == tripID }
        )
        return try? context.fetch(descriptor).first
    }
}
