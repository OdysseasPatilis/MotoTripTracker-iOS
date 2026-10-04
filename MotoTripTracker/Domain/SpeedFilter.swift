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
    /// A motorcycle GPS fix above this is a spike, not a top speed.
    static let maxPlausibleSpeedKmh = 300.0

    func isValid(_ location: CLLocation) -> Bool {
        location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= minAccuracyMeters
    }

    func processedSpeed(from location: CLLocation, previous: CLLocation? = nil) -> CLLocationSpeed {
        let reported = location.speed
        if reported >= 0 {
            return credible(reported, speedAccuracy: location.speedAccuracy)
        }
        // Core Location often reports speed = -1 in background or after wake.
        guard let previous else { return 0 }
        let timeDelta = location.timestamp.timeIntervalSince(previous.timestamp)
        guard timeDelta > 0 else { return 0 }
        let computed = previous.distance(from: location) / timeDelta
        return credible(computed, speedAccuracy: -1)
    }

    /// Zero when the fix is standing-still noise or faster than a real ride.
    private func credible(_ speed: CLLocationSpeed, speedAccuracy: CLLocationSpeed) -> CLLocationSpeed {
        if isStationaryNoise(speed, speedAccuracy: speedAccuracy) { return 0 }
        if speed * 3.6 > Self.maxPlausibleSpeedKmh { return 0 }
        return speed
    }

    /// A fix is noise when it is below a walking pace, or slow and no more certain than zero.
    private func isStationaryNoise(_ speed: CLLocationSpeed, speedAccuracy: CLLocationSpeed) -> Bool {
        if speed < minSpeedMps { return true }
        return speedAccuracy >= 0 && speed < noiseBandMps && speed <= speedAccuracy
    }
}
