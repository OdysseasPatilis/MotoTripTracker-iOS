import CoreLocation
import Foundation

/// Pure camera framing for ride-follow: look-ahead center + cruise / turn-approach distance.
nonisolated enum RideFollowCameraPolicy {
    /// Preserve today's riding pull-back curve.
    static func cruiseDistanceMeters(speedKmh: Double) -> CLLocationDistance {
        350.0 + min(max(speedKmh, 0), 180) * 7.0
    }

    /// Meters ahead of the rider for map center (speed-scaled; +20% when navigating).
    static func lookAheadMeters(speedKmh: Double, isNavigating: Bool) -> CLLocationDistance {
        let speed = max(speedKmh, 0)
        // ~40 m @ 20 km/h → ~180 m @ 100 km/h
        let base = 10.0 + min(speed, 160) * 1.7
        return isNavigating ? base * 1.2 : base
    }

    /// Distance-to-maneuver at which turn zoom begins.
    static func approachWindowMeters(speedKmh: Double) -> CLLocationDistance {
        let speed = min(max(speedKmh, 0), 160)
        // 40→135, 80→250, 120→375
        let window = 20.0 + speed * 2.95
        return min(max(window, 120), 400)
    }

    static func cameraDistanceMeters(
        speedKmh: Double,
        distanceToNextManeuver: CLLocationDistance?,
        isNavigating: Bool,
        isRecalculating: Bool
    ) -> CLLocationDistance {
        let cruise = cruiseDistanceMeters(speedKmh: speedKmh)
        guard isNavigating,
              !isRecalculating,
              let toTurn = distanceToNextManeuver,
              toTurn >= 0 else {
            return cruise
        }
        let window = approachWindowMeters(speedKmh: speedKmh)
        guard toTurn <= window else { return cruise }

        let closest = max(cruise * 0.55, 220)
        let progress = 1.0 - (toTurn / window) // 0 at window edge, 1 at turn
        let t = min(max(progress, 0), 1)
        return cruise + (closest - cruise) * t
    }

    static func centerCoordinate(
        rider: CLLocationCoordinate2D,
        courseDegrees: CLLocationDirection,
        speedKmh: Double,
        isNavigating: Bool
    ) -> CLLocationCoordinate2D {
        guard courseDegrees >= 0 else { return rider }
        let meters = lookAheadMeters(speedKmh: speedKmh, isNavigating: isNavigating)
        return coordinateAhead(of: rider, courseDegrees: courseDegrees, meters: meters)
    }

    static func coordinateAhead(
        of coordinate: CLLocationCoordinate2D,
        courseDegrees: CLLocationDirection,
        meters: CLLocationDistance
    ) -> CLLocationCoordinate2D {
        guard meters > 0 else { return coordinate }
        let earthRadius = 6_371_000.0
        let bearing = courseDegrees * .pi / 180
        let lat1 = coordinate.latitude * .pi / 180
        let lon1 = coordinate.longitude * .pi / 180
        let angular = meters / earthRadius

        let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(bearing))
        let lon2 = lon1 + atan2(
            sin(bearing) * sin(angular) * cos(lat1),
            cos(angular) - sin(lat1) * sin(lat2)
        )

        return CLLocationCoordinate2D(
            latitude: lat2 * 180 / .pi,
            longitude: lon2 * 180 / .pi
        )
    }
}
