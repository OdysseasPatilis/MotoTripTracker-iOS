import CoreLocation
import Foundation

/// Requires a continuous off-route stretch before navigation recalculates.
/// One jittered fix past the threshold used to build a new route on the wrong street.
struct OffRouteGate {
    static let accuracyCeiling: CLLocationAccuracy = 50

    var dwell: TimeInterval = 7
    private var since: Date?

    mutating func shouldRecalculate(
        nearestDistance: CLLocationDistance,
        threshold: CLLocationDistance,
        horizontalAccuracy: CLLocationAccuracy,
        now: Date
    ) -> Bool {
        // A coarse fix is not evidence either way. Leave the dwell clock alone.
        guard horizontalAccuracy >= 0, horizontalAccuracy <= Self.accuracyCeiling else {
            return false
        }
        guard nearestDistance > threshold else {
            since = nil
            return false
        }
        if since == nil {
            since = now
        }
        guard let since else { return false }
        return now.timeIntervalSince(since) >= dwell
    }

    mutating func reset() {
        since = nil
    }
}
