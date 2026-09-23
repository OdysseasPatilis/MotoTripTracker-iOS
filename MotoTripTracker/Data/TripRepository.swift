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
        let points = routePoints(for: tripID)
        guard !points.isEmpty else { return }
        if points.contains(where: \.isWaypoint) {
            return
        }
        let distance = totalDistanceMeters
            ?? fetchTrip(id: tripID)?.distanceMeters
            ?? 0
        await WaypointAnalyzer.analyzeAndMarkWaypoints(
            points: points,
            totalDistanceMeters: distance
        )
        do {
            try modelContext.save()
            let waypointCount = points.filter(\.isWaypoint).count
            AppLogger.persistence.info(
                "Waypoints saved id=\(AppLogger.uuidShort(tripID), privacy: .public) count=\(waypointCount)"
            )
        } catch {
            AppLogger.persistence.error(
                "Failed to save waypoints: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func renameTrip(id: UUID, title: String?) {
        guard let trip = fetchTrip(id: id) else { return }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        trip.title = (trimmed?.isEmpty == false) ? trimmed : nil
        saveContext(action: "rename")
    }

    func toggleFavorite(id: UUID) {
        guard let trip = fetchTrip(id: id) else { return }
        trip.isFavorite.toggle()
        saveContext(action: "favorite")
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
        let orphans = allTrips().filter { $0.endTime <= 0 && $0.startTime > 0 }
        guard !orphans.isEmpty else { return }
        for trip in orphans {
            AppLogger.persistence.notice(
                "Removing orphaned trip id=\(AppLogger.uuidShort(trip.id), privacy: .public)"
            )
            modelContext.delete(trip)
        }
        do {
            try modelContext.save()
        } catch {
            AppLogger.persistence.error(
                "Failed to remove orphaned trips: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Fixes rides whose moving+stopped time was truncated by sub-second GPS integer division.
    func repairUndercountedTripTimings() {
        var repaired = 0
        for trip in allTrips() {
            let points = trip.routePoints
            guard TripTimingRecomputer.looksUndercounted(
                movingSeconds: trip.movingTime,
                stoppedSeconds: trip.stoppedTime,
                points: points
            ) else { continue }

            let times = TripTimingRecomputer.times(from: points)
            let before = trip.movingTime + trip.stoppedTime
            trip.movingTime = times.movingSeconds
            trip.stoppedTime = times.stoppedSeconds
            trip.avgSpeed = RideDistanceFilter.averageSpeedKmh(
                distanceMeters: trip.distanceMeters,
                movingTimeSeconds: times.movingSeconds,
                maxSpeedKmh: trip.maxSpeed
            )
            repaired += 1
            AppLogger.persistence.notice(
                "Repaired trip timing id=\(AppLogger.uuidShort(trip.id), privacy: .public) \(before)s → \(times.movingSeconds + times.stoppedSeconds)s"
            )
        }
        guard repaired > 0 else { return }
        do {
            try modelContext.save()
            AppLogger.persistence.notice("Repaired timings on \(repaired) trip(s)")
        } catch {
            AppLogger.persistence.error(
                "Failed to save repaired timings: \(error.localizedDescription, privacy: .public)"
            )
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
        if let trip = fetchTrip(id: tripID) {
            TripCloudUploader.enqueueUpload(trip: trip, points: routePoints(for: tripID))
        }
        await ensureWaypointsAnalyzed(tripID: tripID, totalDistanceMeters: distanceMeters)
    }

    private func saveContext(action: String) {
        do {
            try modelContext.save()
            AppLogger.persistence.debug("Trip \(action) saved")
        } catch {
            AppLogger.persistence.error("Failed to \(action): \(error.localizedDescription, privacy: .public)")
        }
    }
}
