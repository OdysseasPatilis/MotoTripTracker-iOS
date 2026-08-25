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

    func processedSpeed(from location: CLLocation) -> CLLocationSpeed {
        let speed = location.speed
        guard speed >= 0 else { return 0 }
        return speed < minSpeedMps ? 0 : speed
    }
}
