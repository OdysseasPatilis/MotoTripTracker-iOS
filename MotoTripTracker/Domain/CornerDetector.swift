import CoreLocation
import Foundation

/// Counts corners from GPS bearing changes while moving, and estimates peak lateral G
/// via v² / r for the turn radius implied by the heading change.
final class CornerDetector: @unchecked Sendable {
    private var lastBearing: CLLocationDirection?
    private var lastLocation: CLLocation?
    private var accumulatedTurnDeg: Double = 0
    private var inCorner = false

    private(set) var cornerCount = 0
    private(set) var maxEstimatedLateralG: Double = 0
    private(set) var lastEstimatedLateralG: Double = 0

    private static let minSpeedMps: Double = 4 // ~14 km/h
    private static let noiseDeg: Double = 2
    private static let cornerStartDeg: Double = 12
    private static let cornerCompleteDeg: Double = 35
    private static let minRadiusM: Double = 8
    private static let maxRadiusM: Double = 250

    func reset() {
        lastBearing = nil
        lastLocation = nil
        accumulatedTurnDeg = 0
        inCorner = false
        cornerCount = 0
        maxEstimatedLateralG = 0
        lastEstimatedLateralG = 0
    }

    @discardableResult
    func onLocation(_ location: CLLocation, speedMps: Double) -> Bool {
        guard location.course >= 0, speedMps >= Self.minSpeedMps else {
            finishCornerIfNeeded()
            lastBearing = nil
            lastLocation = location
            lastEstimatedLateralG *= 0.85
            return false
        }

        let bearing = location.course
        let prevBearing = lastBearing
        let prev = lastLocation
        lastBearing = bearing
        lastLocation = location

        guard let prevBearing, let prev else { return false }

        let delta = Self.shortestAngleDeg(bearing - prevBearing)
        let absDelta = abs(delta)
        guard absDelta >= Self.noiseDeg else { return false }

        let sameDirection = accumulatedTurnDeg == 0
            || (accumulatedTurnDeg > 0 && delta > 0)
            || (accumulatedTurnDeg < 0 && delta < 0)

        if !sameDirection {
            finishCornerIfNeeded()
        }

        accumulatedTurnDeg += delta
        inCorner = abs(accumulatedTurnDeg) >= Self.cornerStartDeg

        let distance = prev.distance(from: location)
        if distance > 1, absDelta > 0.5 {
            let turnRad = absDelta * .pi / 180
            let radius = distance / turnRad
            if radius >= Self.minRadiusM, radius <= Self.maxRadiusM {
                let lateralG = (speedMps * speedMps / radius) / 9.81
                if lateralG >= 0.05, lateralG <= 2.5 {
                    lastEstimatedLateralG = lateralG
                    maxEstimatedLateralG = max(maxEstimatedLateralG, lateralG)
                }
            }
        }

        if abs(accumulatedTurnDeg) >= Self.cornerCompleteDeg {
            cornerCount += 1
            accumulatedTurnDeg = 0
            inCorner = false
            return true
        }
        return false
    }

    private func finishCornerIfNeeded() {
        if inCorner, abs(accumulatedTurnDeg) >= Self.cornerCompleteDeg * 0.7 {
            cornerCount += 1
        }
        accumulatedTurnDeg = 0
        inCorner = false
    }

    private static func shortestAngleDeg(_ delta: Double) -> Double {
        var d = delta
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        return d
    }
}
