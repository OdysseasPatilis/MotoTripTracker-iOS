import Foundation
import os

/// Estimates longitudinal G-force from GPS speed changes.
/// Phone accelerometers on a motorcycle mount are dominated by engine/road vibration
/// (often multi-G spikes), so speed deltas are a more trustworthy riding metric.
@MainActor
final class GForceTracker {
    private(set) var currentGForce: Double = 0
    private(set) var maxSessionGForce: Double = 0

    private var lastSpeedMps: Double?
    private var lastTimestamp: TimeInterval?

    /// Street-riding peak clamp — beyond this is almost always GPS noise.
    private let maxPlausibleG: Double = 1.2
    /// Ignore tiny deltas that look like GPS jitter.
    private let minDeltaSeconds: TimeInterval = 0.4
    private let maxDeltaSeconds: TimeInterval = 4.0

    func startTracking(resetSession: Bool = true) {
        if resetSession {
            currentGForce = 0
            maxSessionGForce = 0
        }
        lastSpeedMps = nil
        lastTimestamp = nil
        AppLogger.sensors.debug("G-force tracking started (GPS-derived, reset=\(resetSession))")
    }

    func stopTracking() {
        currentGForce = 0
        lastSpeedMps = nil
        lastTimestamp = nil
        AppLogger.sensors.debug("G-force tracking stopped")
    }

    /// Feed each accepted GPS sample. Uses |Δv / Δt| / g, smoothed for the UI.
    func update(speedMps: Double, timestamp: TimeInterval) {
        defer {
            lastSpeedMps = speedMps
            lastTimestamp = timestamp
        }

        guard let prevSpeed = lastSpeedMps, let prevTime = lastTimestamp else {
            currentGForce = 0
            return
        }

        let dt = timestamp - prevTime
        guard dt >= minDeltaSeconds, dt <= maxDeltaSeconds else {
            currentGForce *= 0.85
            return
        }

        let accelG = abs(speedMps - prevSpeed) / dt / 9.81
        let clamped = min(accelG, maxPlausibleG)
        // Ignore micro-jitter under ~0.03 G
        let meaningful = clamped > 0.03 ? clamped : 0

        currentGForce = (currentGForce * 0.7) + (meaningful * 0.3)
        // Track max from the smoothed signal so one GPS blip cannot inflate the ride peak.
        if currentGForce > maxSessionGForce {
            maxSessionGForce = currentGForce
        }
    }
}
