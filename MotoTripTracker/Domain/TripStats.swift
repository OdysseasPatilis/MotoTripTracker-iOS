import Foundation

nonisolated enum GpsQuality: String, Equatable, Sendable {
    case unknown
    case excellent
    case good
    case fair
    case poor

    static func fromAccuracyMeters(_ accuracy: Double?) -> GpsQuality {
        guard let accuracy, accuracy > 0 else { return .unknown }
        switch accuracy {
        case ...5: return .excellent
        case ...10: return .good
        case ...20: return .fair
        default: return .poor
        }
    }

    /// Filled signal bars out of 4.
    var barCount: Int {
        switch self {
        case .excellent: 4
        case .good: 3
        case .fair: 2
        case .poor: 1
        case .unknown: 0
        }
    }

    var shortLabel: String {
        switch self {
        case .unknown: "No fix"
        case .excellent: "Excellent"
        case .good: "Good"
        case .fair: "Fair"
        case .poor: "Weak"
        }
    }

    var label: String {
        switch self {
        case .unknown: "GPS —"
        case .excellent: "GPS EXCELLENT"
        case .good: "GPS GOOD"
        case .fair: "GPS FAIR"
        case .poor: "GPS WEAK"
        }
    }
}

nonisolated struct TripStats: Equatable, Sendable {
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
