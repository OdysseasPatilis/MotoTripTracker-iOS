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

        trip.distanceMeters = runningStats.distanceMeters
        trip.movingTime = runningStats.movingTime
        trip.stoppedTime = runningStats.stoppedTime
        trip.maxSpeed = runningStats.maxSpeed
        trip.maxGForce = runningStats.maxGForce
        trip.elevationGain = runningStats.totalElevationGain
        trip.avgSpeed = runningStats.avgSpeed

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
        trip.movingTime = finalStats.movingTime
        trip.stoppedTime = finalStats.stoppedTime
        trip.avgSpeed = finalStats.avgSpeed
        trip.distanceMeters = finalStats.distanceMeters
        trip.maxSpeed = finalStats.maxSpeed
        trip.maxGForce = finalStats.maxGForce
        trip.elevationGain = finalStats.totalElevationGain

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

    func waypoints(for tripID: UUID) -> [RoutePoint] {
        routePoints(for: tripID).filter(\.isWaypoint)
    }
}
