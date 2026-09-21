import Foundation

/// Persistence seam for live ride recording. Domain talks to this instead of SwiftData.
@MainActor
protocol TripPersisting: AnyObject {
    func startNewTrip(startTime: TimeInterval) -> UUID
    func addRoutePointAndUpdateStats(
        tripID: UUID,
        latitude: Double,
        longitude: Double,
        altitude: Double,
        speedMps: Double,
        time: TimeInterval,
        runningStats: TripStats
    )
    func flushPendingRoutePoints()
    func saveTrip(tripID: UUID, finalStats: TripStats, endTime: TimeInterval)
    func deleteTrip(id: UUID)
}
