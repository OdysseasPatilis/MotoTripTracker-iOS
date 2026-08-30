import CoreLocation
import Foundation

/// Converts consecutive GPS fixes into a distance increment that won't blow up average speed.
enum RideDistanceFilter {
    private static let absoluteMaxMeters: CLLocationDistance = 2_000

    /// Prefer GPS speed × elapsed time. Geographic distance is only a sanity check
    /// (jitter of 50–80 m/s would otherwise imply 200–300 km/h of fake distance).
    static func distanceDelta(
        geographicMeters: CLLocationDistance,
        speedMps: CLLocationSpeed,
        timeDelta: TimeInterval
    ) -> CLLocationDistance {
        guard geographicMeters > 0, speedMps > 0, timeDelta > 0 else { return 0 }

        let fromSpeed = speedMps * timeDelta
        // Allow modest lag between reported speed and position, but not GPS wander.
        let allowed = min(absoluteMaxMeters, fromSpeed * 1.2 + 8)

        if geographicMeters > allowed * 2.5 + 40 {
            return 0
        }
        return min(geographicMeters, allowed)
    }

    /// Average cannot exceed peak; also drops impossible values from bad distance.
    static func averageSpeedKmh(distanceMeters: Double, movingTimeSeconds: Int64, maxSpeedKmh: Double) -> Double {
        guard movingTimeSeconds > 0, distanceMeters > 0 else { return 0 }
        let hours = Double(movingTimeSeconds) / 3600
        let raw = (distanceMeters / 1000) / hours
        if maxSpeedKmh > 0 {
            return min(raw, maxSpeedKmh)
        }
        return min(raw, 300)
    }
}
