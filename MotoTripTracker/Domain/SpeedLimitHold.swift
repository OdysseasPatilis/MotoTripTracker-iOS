import CoreLocation
import Foundation

/// Keeps the posted speed limit until a different one has been continuous
/// while the bike actually travels. A GPS fix that wanders into the next
/// grid cell for a few seconds must not flip 90 km/h down to 40.
struct SpeedLimitHold {
    private(set) var displayed: Int?
    private var pending: Int?
    private var pendingSince: Date?
    private var pendingOrigin: CLLocation?

    var confirmAfter: TimeInterval = 6
    var confirmTravelMeters: CLLocationDistance = 80
    /// Refuse a lower limit while GPS speed is still this far above it.
    var lowerLimitSpeedMarginKmh: Double = 25

    mutating func consider(_ candidate: Int, at location: CLLocation) -> Int {
        if displayed == nil {
            displayed = candidate
            clearPending()
            return candidate
        }
        guard let current = displayed else { return candidate }

        if candidate == current {
            clearPending()
            return current
        }

        if pending != candidate {
            pending = candidate
            pendingSince = location.timestamp
            pendingOrigin = location
            return current
        }

        guard let pendingSince, let pendingOrigin else { return current }
        let elapsed = location.timestamp.timeIntervalSince(pendingSince)
        let moved = location.distance(from: pendingOrigin)
        guard elapsed >= confirmAfter, moved >= confirmTravelMeters else { return current }

        if candidate < current, location.speed >= 0 {
            let speedKmh = location.speed * 3.6
            if speedKmh > Double(candidate) + lowerLimitSpeedMarginKmh {
                return current
            }
        }

        displayed = candidate
        clearPending()
        return candidate
    }

    mutating func reset() {
        displayed = nil
        clearPending()
    }

    private mutating func clearPending() {
        pending = nil
        pendingSince = nil
        pendingOrigin = nil
    }
}
