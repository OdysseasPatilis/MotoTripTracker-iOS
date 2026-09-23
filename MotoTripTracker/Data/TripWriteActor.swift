import Foundation
import SwiftData
import os

/// Background SwiftData writer for the live GPS loop.
/// Inserts still happen every tick; `RoutePointSaveGate` still throttles `save()`.
@ModelActor
actor TripWriteActor {
    private var saveGate = RoutePointSaveGate()

    func createTrip(id: UUID, startTime: TimeInterval) {
        saveGate.reset()
        let trip = Trip(id: id, startTime: startTime)
        modelContext.insert(trip)
        saveContext(action: "new trip")
        AppLogger.persistence.notice("New trip created id=\(AppLogger.uuidShort(id), privacy: .public)")
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

        if saveGate.recordPoint(at: time) {
            saveContext(action: "route point batch")
        }
    }

    func flushPendingRoutePoints() {
        guard saveGate.consumeFlush() else { return }
        saveContext(action: "route point flush")
    }

    func saveTrip(tripID: UUID, finalStats: TripStats, endTime: TimeInterval) {
        saveGate.reset()
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

        let coords = points.map { (lat: $0.latitude, lng: $0.longitude) }
        if !coords.isEmpty {
            trip.encodedRoutePolyline = PolylineEncoder.encode(coords)
            AppLogger.persistence.info(
                "Polyline encoded chars=\(trip.encodedRoutePolyline?.count ?? 0) from \(coords.count) points"
            )
        }
        saveContext(action: "finalize")
        AppLogger.persistence.notice("Trip stats+polyline saved id=\(AppLogger.uuidShort(tripID), privacy: .public)")
    }

    func deleteTrip(id: UUID) {
        saveGate.reset()
        guard let trip = fetchTrip(id: id) else {
            AppLogger.persistence.warning("Delete skipped — trip not found id=\(AppLogger.uuidShort(id), privacy: .public)")
            return
        }
        modelContext.delete(trip)
        saveContext(action: "delete")
        AppLogger.persistence.notice("Trip deleted id=\(AppLogger.uuidShort(id), privacy: .public)")
    }

    private func fetchTrip(id: UUID) -> Trip? {
        let descriptor = FetchDescriptor<Trip>(
            predicate: #Predicate { $0.id == id }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func routePoints(for tripID: UUID) -> [RoutePoint] {
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
