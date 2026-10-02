import CoreLocation
import Foundation

struct SpeedFilter: Sendable {
    /// 15 m — good threshold for a motorcycle on a road.
    private let minAccuracyMeters: CLLocationAccuracy = 15
    /// Ignore speeds under ~7 km/h. Indoor GPS often reports 4–5 km/h while standing still.
    static let stationaryFloorMps: CLLocationSpeed = 2
    private let minSpeedMps: CLLocationSpeed = stationaryFloorMps
    /// Above the floor, still drop a reading whose uncertainty includes zero, up to ~14 km/h.
    private let noiseBandMps: CLLocationSpeed = 4

    func isValid(_ location: CLLocation) -> Bool {
        location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= minAccuracyMeters
    }

    func processedSpeed(from location: CLLocation, previous: CLLocation? = nil) -> CLLocationSpeed {
        let reported = location.speed
        if reported >= 0 {
            return isStationaryNoise(reported, speedAccuracy: location.speedAccuracy) ? 0 : reported
        }
        // Core Location often reports speed = -1 in background or after wake.
        guard let previous else { return 0 }
        let timeDelta = location.timestamp.timeIntervalSince(previous.timestamp)
        guard timeDelta > 0 else { return 0 }
        let computed = previous.distance(from: location) / timeDelta
        return computed < minSpeedMps ? 0 : computed
    }

    /// A fix is noise when it is below a walking pace, or slow and no more certain than zero.
    private func isStationaryNoise(_ speed: CLLocationSpeed, speedAccuracy: CLLocationSpeed) -> Bool {
        if speed < minSpeedMps { return true }
        return speedAccuracy >= 0 && speed < noiseBandMps && speed <= speedAccuracy
    }
}
