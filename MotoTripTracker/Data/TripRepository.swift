import Foundation
import SwiftData
import os

@MainActor
final class TripRepository: TripPersisting {
    private let modelContext: ModelContext
    private let writer: TripWriteActor
    private var writeChain: Task<Void, Never> = Task {}

    init(modelContext: ModelContext, container: ModelContainer) {
        self.modelContext = modelContext
        self.writer = TripWriteActor(modelContainer: container)
        AppLogger.persistence.debug("TripRepository initialized")
    }

    func waitForPendingWrites() async {
        await writeChain.value
    }

    @discardableResult
    func startNewTrip(startTime: TimeInterval) -> UUID {
        let id = UUID()
        let writer = writer
        enqueueWrite {
            await writer.createTrip(id: id, startTime: startTime)
        }
        return id
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
        let writer = writer
        enqueueWrite {
            await writer.addRoutePointAndUpdateStats(
                tripID: tripID,
                latitude: latitude,
                longitude: longitude,
                altitude: altitude,
                speedMps: speedMps,
                time: time,
                runningStats: runningStats
            )
        }
    }

    /// Writes any GPS points still sitting in the writer (pause / background).
    func flushPendingRoutePoints() {
        let writer = writer
        enqueueWrite {
            await writer.flushPendingRoutePoints()
        }
    }

    func saveTrip(tripID: UUID, finalStats: TripStats, endTime: TimeInterval) {
        let writer = writer
        enqueueWrite { [weak self] in
            await writer.saveTrip(tripID: tripID, finalStats: finalStats, endTime: endTime)
            await self?.finishSavedTrip(tripID: tripID, distanceMeters: finalStats.distanceMeters)
        }
    }

    /// Marks START/END/summit/stops when missing. Safe to call again from Full Route.
    func ensureWaypointsAnalyzed(tripID: UUID, totalDistanceMeters: Double? = nil) async {
        let writer = writer
        enqueueWrite {
            await writer.analyzeAndSaveWaypoints(
                tripID: tripID,
                totalDistanceMeters: totalDistanceMeters
            )
        }
        await waitForPendingWrites()
    }

    func renameTrip(id: UUID, title: String?) {
        let writer = writer
        enqueueWrite {
            await writer.renameTrip(id: id, title: title)
        }
    }

    func toggleFavorite(id: UUID) {
        let writer = writer
        enqueueWrite {
            await writer.toggleFavorite(id: id)
        }
    }

    func uploadTrip(id: UUID) async throws {
        guard let trip = fetchTrip(id: id) else {
            throw TripCloudUploader.UploadError.tripNotFound
        }
        let points = routePoints(for: id)
        try await TripCloudUploader.uploadNow(trip: trip, points: points)
    }

    func allTrips() -> [Trip] {
        let descriptor = FetchDescriptor<Trip>(
            sortBy: [SortDescriptor(\.startTime, order: .reverse)]
        )
        let trips = (try? modelContext.fetch(descriptor)) ?? []
        AppLogger.persistence.debug("Fetched \(trips.count) trips from history")
        return trips
    }

    func fetchTrip(id: UUID) -> Trip? {
        let descriptor = FetchDescriptor<Trip>(
            predicate: #Predicate { $0.id == id }
        )
        return try? modelContext.fetch(descriptor).first
    }

    func deleteTrip(id: UUID) {
        let writer = writer
        enqueueWrite {
            await writer.deleteTrip(id: id)
        }
    }

    func routePoints(for tripID: UUID) -> [RoutePoint] {
        // Prefer an explicit fetch — relationship arrays can appear empty under memory
        // pressure after long background rides even when rows exist.
        let descriptor = FetchDescriptor<RoutePoint>(
            predicate: #Predicate { point in
                point.trip?.id == tripID
            },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        if let fetched = try? modelContext.fetch(descriptor), !fetched.isEmpty {
            return fetched
        }
        guard let trip = fetchTrip(id: tripID) else { return [] }
        return trip.routePoints.sorted { $0.timestamp < $1.timestamp }
    }

    /// Removes trips left open when the app was force-quit mid-ride (endTime still zero).
    func recoverOrphanedTrips() {
        let writer = writer
        enqueueWrite {
            await writer.recoverOrphanedTrips()
        }
    }

    /// Fixes rides whose moving+stopped time was truncated by sub-second GPS integer division.
    func repairUndercountedTripTimings() {
        let writer = writer
        enqueueWrite {
            await writer.repairUndercountedTripTimings()
        }
    }

    func waypoints(for tripID: UUID) -> [RoutePoint] {
        routePoints(for: tripID).filter(\.isWaypoint)
    }

    private func enqueueWrite(_ work: @escaping @Sendable () async -> Void) {
        writeChain = Task { [writeChain] in
            await writeChain.value
            await work()
        }
    }

    private func finishSavedTrip(tripID: UUID, distanceMeters: Double) async {
        await writer.analyzeAndSaveWaypoints(
            tripID: tripID,
            totalDistanceMeters: distanceMeters
        )
        if let trip = fetchTrip(id: tripID) {
            TripCloudUploader.enqueueUpload(trip: trip, points: routePoints(for: tripID))
        }
    }
}
