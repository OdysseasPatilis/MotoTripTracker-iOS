import Foundation

nonisolated struct RideSessionState: Equatable, Sendable {
    var stats: TripStats = TripStats()
    var isActive: Bool = false
    var isPaused: Bool = false
}
