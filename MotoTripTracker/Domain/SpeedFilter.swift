import CoreLocation
import Foundation

struct SpeedFilter: Sendable {
    /// 15 m — good threshold for a motorcycle on a road.
    private let minAccuracyMeters: CLLocationAccuracy = 15
    /// Ignore speeds under ~3 km/h to kill GPS drift while parked.
    private let minSpeedMps: CLLocationSpeed = 0.83

    func isValid(_ location: CLLocation) -> Bool {
        location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= minAccuracyMeters
    }

    func processedSpeed(from location: CLLocation, previous: CLLocation? = nil) -> CLLocationSpeed {
        let reported = location.speed
        if reported >= 0 {
            return reported < minSpeedMps ? 0 : reported
        }
        // Core Location often reports speed = -1 in background or after wake.
        guard let previous else { return 0 }
        let timeDelta = location.timestamp.timeIntervalSince(previous.timestamp)
        guard timeDelta > 0 else { return 0 }
        let computed = previous.distance(from: location) / timeDelta
        return computed < minSpeedMps ? 0 : computed
    }
}
