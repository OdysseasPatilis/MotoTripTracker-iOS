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

    func recoverOrphanedTrips() {
        let orphans = allTrips().filter { $0.endTime <= 0 && $0.startTime > 0 }
        guard !orphans.isEmpty else { return }
        for trip in orphans {
            AppLogger.persistence.notice(
                "Removing orphaned trip id=\(AppLogger.uuidShort(trip.id), privacy: .public)"
            )
            modelContext.delete(trip)
        }
        saveContext(action: "recover orphans")
    }

    func repairUndercountedTripTimings() {
        var repaired = 0
        for trip in allTrips() {
            let points = routePoints(for: trip.id)
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
        saveContext(action: "repair timings")
        AppLogger.persistence.notice("Repaired timings on \(repaired) trip(s)")
    }

    func analyzeAndSaveWaypoints(
        tripID: UUID,
        totalDistanceMeters: Double?,
        geocodeAddresses: Bool = true
    ) async {
        let points = routePoints(for: tripID)
        guard !points.isEmpty else { return }
        if points.contains(where: \.isWaypoint) { return }
        let distance = totalDistanceMeters ?? fetchTrip(id: tripID)?.distanceMeters ?? 0
        let samples = points.map {
            WaypointSample(
                id: $0.id,
                latitude: $0.latitude,
                longitude: $0.longitude,
                altitude: $0.altitude,
                speedMps: $0.speedMps,
                timestamp: $0.timestamp
            )
        }
        let marks = await WaypointAnalyzer.analyze(
            points: samples,
            totalDistanceMeters: distance,
            geocodeAddresses: geocodeAddresses
        )
        let pointsByID = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) })
        for mark in marks {
            guard let point = pointsByID[mark.pointID] else { continue }
            point.isWaypoint = true
            point.waypointType = mark.type
            point.waypointTitle = mark.title
            point.waypointSubtitle = mark.subtitle
        }
        saveContext(action: "waypoints")
        let waypointCount = marks.count
        AppLogger.persistence.info(
            "Waypoints saved id=\(AppLogger.uuidShort(tripID), privacy: .public) count=\(waypointCount)"
        )
    }

    private func fetchTrip(id: UUID) -> Trip? {
        let descriptor = FetchDescriptor<Trip>(
            predicate: #Predicate { $0.id == id }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func allTrips() -> [Trip] {
        let descriptor = FetchDescriptor<Trip>(
            sortBy: [SortDescriptor(\.startTime, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
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
