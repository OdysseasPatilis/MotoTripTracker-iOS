import Foundation

enum GpsQuality: String, Equatable, Sendable {
    case unknown
    case good
    case fair
    case poor

    static func fromAccuracyMeters(_ accuracy: Double?) -> GpsQuality {
        guard let accuracy, accuracy > 0 else { return .unknown }
        switch accuracy {
        case ...8: return .good
        case ...15: return .fair
        default: return .poor
        }
    }

    var label: String {
        switch self {
        case .unknown: "GPS —"
        case .good: "GPS GOOD"
        case .fair: "GPS FAIR"
        case .poor: "GPS WEAK"
        }
    }
}

struct TripStats: Equatable, Sendable {
    var speed: Double = 0
    var distanceMeters: Double = 0
    var tripStartTime: TimeInterval = 0
    var movingTime: Int64 = 0
    var stoppedTime: Int64 = 0
    var maxSpeed: Double = 0
    var currentGForce: Double = 0
    var maxGForce: Double = 0
    var currentLateralGForce: Double = 0
    var maxLateralGForce: Double = 0
    var cornerCount: Int = 0
    var elevation: Double = 0
    var avgSpeed: Double = 0
    var totalElevationGain: Double = 0
    var gpsAccuracyMeters: Double?
    var gpsQuality: GpsQuality = .unknown

    var tripTime: Int64 { movingTime + stoppedTime }
    var distanceKm: Double { distanceMeters / 1000 }
}
