import CoreLocation
import Foundation

/// Decides when a rider has actually left the planned road.
///
/// A matching course with a sideways GPS error stays on the route. A real wrong
/// turn changes course and then has to keep moving before we ask MapKit for a new route.
struct OffRouteGate {
    var commitTravelMeters: CLLocationDistance = 50

    private(set) var isDiverging = false
    private var traveled: CLLocationDistance = 0
    private var last: CLLocation?

    mutating func shouldRecalculate(
        crossTrack: CLLocationDistance,
        horizontalAccuracy: CLLocationAccuracy,
        course: CLLocationDirection,
        routeBearing: CLLocationDirection,
        speedMps: CLLocationSpeed,
        location: CLLocation
    ) -> Bool {
        guard diverged(
            crossTrack: crossTrack,
            horizontalAccuracy: horizontalAccuracy,
            course: course,
            routeBearing: routeBearing,
            speedMps: speedMps
        ) else {
            isDiverging = false
            traveled = 0
            last = location
            return false
        }

        isDiverging = true
        defer { last = location }

        // A parked fix wanders without the bike leaving the road.
        guard speedMps < 0 || speedMps >= 1.5 else { return false }

        if let last {
            let step = location.distance(from: last)
            let dt = location.timestamp.timeIntervalSince(last.timestamp)
            let plausible = step <= 120 && (dt <= 0 || step / dt <= 70)
            if plausible {
                traveled += step
            }
        }
        return traveled >= commitTravelMeters
    }

    mutating func reset() {
        isDiverging = false
        traveled = 0
        last = nil
    }

    /// Same direction as the route: only a large sideways error counts.
    /// A different direction counts once the fix is outside its own accuracy.
    private func diverged(
        crossTrack: CLLocationDistance,
        horizontalAccuracy: CLLocationAccuracy,
        course: CLLocationDirection,
        routeBearing: CLLocationDirection,
        speedMps: CLLocationSpeed
    ) -> Bool {
        let accuracy = horizontalAccuracy >= 0 ? horizontalAccuracy : 30
        let headingKnown = course >= 0 && speedMps >= 3
        let aligned = !headingKnown || NavigationRouteMath.angularDifference(course, routeBearing) <= 40
        let limit = aligned ? max(40, accuracy + 15) : max(25, accuracy * 0.5 + 12)
        return crossTrack > limit
    }
}
