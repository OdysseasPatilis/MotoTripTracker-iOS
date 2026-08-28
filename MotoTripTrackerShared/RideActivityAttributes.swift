import ActivityKit
import Foundation

/// Shared ActivityKit attributes for an in-progress motorcycle ride.
/// Compiled into both the app and the widget extension.
nonisolated struct RideActivityAttributes: ActivityAttributes {
    /// Static for the lifetime of the activity.
    public struct ContentState: Codable, Hashable, Sendable {
        var speedKmh: Int
        var speedLimitKmh: Int
        var distanceKm: Double
        var movingTimeSeconds: Int64
        var isPaused: Bool
        var isOverLimit: Bool
        /// Compact nav line, e.g. "4.2 km · ETA 12:40". Empty when no destination.
        var navigationSummary: String
    }

    /// Ride start (epoch). Kept in attributes so the Lock Screen can show elapsed context.
    var startedAt: Date
}
