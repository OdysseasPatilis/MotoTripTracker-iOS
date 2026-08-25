import Foundation
import SwiftData

@MainActor
final class TripRepository {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    @discardableResult
    func startNewTrip(startTime: TimeInterval) -> UUID {
        let trip = Trip(startTime: startTime)
        modelContext.insert(trip)
        try? modelContext.save()
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
        guard let trip = fetchTrip(id: tripID) else { return }

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

        try? modelContext.save()
    }

    func saveTrip(tripID: UUID, finalStats: TripStats, endTime: TimeInterval) {
        guard let trip = fetchTrip(id: tripID) else { return }

        trip.endTime = endTime
        trip.movingTime = finalStats.movingTime
        trip.stoppedTime = finalStats.stoppedTime
        trip.avgSpeed = finalStats.avgSpeed
        trip.distanceMeters = finalStats.distanceMeters
        trip.maxSpeed = finalStats.maxSpeed
        trip.maxGForce = finalStats.maxGForce
        trip.elevationGain = finalStats.totalElevationGain

        let points = routePoints(for: tripID)
        Task {
            await WaypointAnalyzer.analyzeAndMarkWaypoints(
                points: points,
                totalDistanceMeters: finalStats.distanceMeters
            )
            let coords = points.map { (lat: $0.latitude, lng: $0.longitude) }
            if !coords.isEmpty {
                trip.encodedRoutePolyline = PolylineEncoder.encode(coords)
            }
            try? modelContext.save()
        }
    }

    func allTrips() -> [Trip] {
        let descriptor = FetchDescriptor<Trip>(
            sortBy: [SortDescriptor(\.startTime, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func fetchTrip(id: UUID) -> Trip? {
        let descriptor = FetchDescriptor<Trip>(
            predicate: #Predicate { $0.id == id }
        )
        return try? modelContext.fetch(descriptor).first
    }

    func deleteTrip(id: UUID) {
        guard let trip = fetchTrip(id: id) else { return }
        modelContext.delete(trip)
        try? modelContext.save()
    }

    func routePoints(for tripID: UUID) -> [RoutePoint] {
        guard let trip = fetchTrip(id: tripID) else { return [] }
        return trip.routePoints.sorted { $0.timestamp < $1.timestamp }
    }

    func waypoints(for tripID: UUID) -> [RoutePoint] {
        routePoints(for: tripID).filter(\.isWaypoint)
    }
}
