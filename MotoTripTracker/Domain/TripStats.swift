import Foundation

struct TripStats: Equatable, Sendable {
    var speed: Double = 0
    var distanceMeters: Double = 0
    var tripStartTime: TimeInterval = 0
    var movingTime: Int64 = 0
    var stoppedTime: Int64 = 0
    var maxSpeed: Double = 0
    var currentGForce: Double = 0
    var maxGForce: Double = 0
    var elevation: Double = 0
    var avgSpeed: Double = 0
    var totalElevationGain: Double = 0

    var tripTime: Int64 { movingTime + stoppedTime }
    var distanceKm: Double { distanceMeters / 1000 }
}
