import Foundation
import SwiftData
import os

@MainActor
final class TripRepository {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        AppLogger.persistence.debug("TripRepository initialized")
    }

    @discardableResult
    func startNewTrip(startTime: TimeInterval) -> UUID {
        let trip = Trip(startTime: startTime)
        modelContext.insert(trip)
        do {
            try modelContext.save()
            AppLogger.persistence.notice("New trip created id=\(AppLogger.uuidShort(trip.id), privacy: .public)")
        } catch {
            AppLogger.persistence.error("Failed to save new trip: \(error.localizedDescription, privacy: .public)")
        }
        return trip.id
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
        guard let trip = fetchTrip(id: tripID) else {
            AppLogger.persistence.error("Route point skipped — trip not found id=\(AppLogger.uuidShort(tripID), privacy: .public)")
            return
        }

        let point = RoutePoint(
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            speedMps: speedMps,
            timestamp: time
        )
        point.trip = trip
        modelContext.insert(point)

        applyRunningStats(runningStats, to: trip)

        do {
            try modelContext.save()
        } catch {
            AppLogger.persistence.error("Failed to persist route point: \(error.localizedDescription, privacy: .public)")
        }
    }

    func saveTrip(tripID: UUID, finalStats: TripStats, endTime: TimeInterval) {
        guard let trip = fetchTrip(id: tripID) else {
            AppLogger.persistence.error("Finalize skipped — trip not found id=\(AppLogger.uuidShort(tripID), privacy: .public)")
            return
        }

        trip.endTime = endTime
        applyRunningStats(finalStats, to: trip)

        let points = routePoints(for: tripID)
        AppLogger.persistence.notice(
            "Finalizing trip id=\(AppLogger.uuidShort(tripID), privacy: .public) points=\(points.count) dist=\(finalStats.distanceKm, format: .fixed(precision: 2))km"
        )

        Task {
            await WaypointAnalyzer.analyzeAndMarkWaypoints(
                points: points,
                totalDistanceMeters: finalStats.distanceMeters
            )
            let waypointCount = points.filter(\.isWaypoint).count
            let coords = points.map { (lat: $0.latitude, lng: $0.longitude) }
            if !coords.isEmpty {
                trip.encodedRoutePolyline = PolylineEncoder.encode(coords)
                AppLogger.persistence.info(
                    "Polyline encoded chars=\(trip.encodedRoutePolyline?.count ?? 0) waypoints=\(waypointCount)"
                )
            }
            do {
                try modelContext.save()
                AppLogger.persistence.notice("Trip saved id=\(AppLogger.uuidShort(tripID), privacy: .public)")
            } catch {
                AppLogger.persistence.error("Failed to save finalized trip: \(error.localizedDescription, privacy: .public)")
            }
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
        guard let trip = fetchTrip(id: id) else {
            AppLogger.persistence.warning("Delete skipped — trip not found id=\(AppLogger.uuidShort(id), privacy: .public)")
            return
        }
        modelContext.delete(trip)
        do {
            try modelContext.save()
            AppLogger.persistence.notice("Trip deleted id=\(AppLogger.uuidShort(id), privacy: .public)")
        } catch {
            AppLogger.persistence.error("Failed to delete trip: \(error.localizedDescription, privacy: .public)")
        }
    }

    func routePoints(for tripID: UUID) -> [RoutePoint] {
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

    private func applyRunningStats(_ stats: TripStats, to trip: Trip) {
        trip.distanceMeters = stats.distanceMeters
        trip.movingTime = stats.movingTime
        trip.stoppedTime = stats.stoppedTime
        trip.maxSpeed = stats.maxSpeed
        trip.maxGForce = stats.maxGForce
        trip.elevationGain = stats.totalElevationGain
        trip.avgSpeed = stats.avgSpeed
        trip.maxLateralGForce = stats.maxLateralGForce
        trip.cornerCount = stats.cornerCount
        trip.twistinessScore = TwistinessCalculator.score(
            cornerCount: stats.cornerCount,
            distanceKm: stats.distanceKm,
            maxLateralGForce: stats.maxLateralGForce
        )
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
