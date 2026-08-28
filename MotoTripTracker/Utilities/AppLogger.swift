import Foundation
import os

/// Unified logging for MotoTripTracker — filter by category in Console.app.
enum AppLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.odys.MotoTripTracker"

    static let app = Logger(subsystem: subsystem, category: "App")
    static let location = Logger(subsystem: subsystem, category: "Location")
    static let trip = Logger(subsystem: subsystem, category: "Trip")
    static let persistence = Logger(subsystem: subsystem, category: "Persistence")
    static let speedLimit = Logger(subsystem: subsystem, category: "SpeedLimit")
    static let navigation = Logger(subsystem: subsystem, category: "Navigation")
    static let waypoint = Logger(subsystem: subsystem, category: "Waypoint")
    static let sensors = Logger(subsystem: subsystem, category: "Sensors")

    static func coordinate(_ lat: Double, _ lon: Double) -> String {
        String(format: "%.5f,%.5f", lat, lon)
    }

    static func tripSummary(_ stats: TripStats) -> String {
        String(
            format: "dist=%.2fkm speed=%.0f avg=%.0f max=%.0f moving=%ds stopped=%ds elev=%.0fm maxG=%.2f latG=%.2f corners=%d gps=%@",
            stats.distanceKm,
            stats.speed,
            stats.avgSpeed,
            stats.maxSpeed,
            stats.movingTime,
            stats.stoppedTime,
            stats.totalElevationGain,
            stats.maxGForce,
            stats.maxLateralGForce,
            stats.cornerCount,
            stats.gpsQuality.rawValue
        )
    }

    static func uuidShort(_ id: UUID) -> String {
        id.uuidString.prefix(8).uppercased()
    }
}

/// Prevents log floods from 1 Hz GPS / sensor streams.
enum LogThrottle {
    private static var lastLogged: [String: Date] = [:]

    @MainActor
    static func shouldLog(key: String, interval: TimeInterval) -> Bool {
        let now = Date()
        if let last = lastLogged[key], now.timeIntervalSince(last) < interval {
            return false
        }
        lastLogged[key] = now
        return true
    }

    @MainActor
    static func reset(key: String) {
        lastLogged.removeValue(forKey: key)
    }
}
