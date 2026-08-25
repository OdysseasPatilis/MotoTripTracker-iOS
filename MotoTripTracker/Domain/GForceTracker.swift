import CoreMotion
import Foundation
import os

/// Tracks linear acceleration (gravity-free) and exposes G-force for the live ride loop.
@MainActor
final class GForceTracker {
    private let motionManager = CMMotionManager()
    private(set) var currentGForce: Double = 0
    private(set) var maxSessionGForce: Double = 0

    func startTracking(resetSession: Bool = true) {
        if resetSession {
            currentGForce = 0
            maxSessionGForce = 0
        }

        guard motionManager.isDeviceMotionAvailable else {
            AppLogger.sensors.warning("Device motion unavailable — G-force disabled")
            return
        }
        motionManager.deviceMotionUpdateInterval = 1.0 / 50.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.handle(userAcceleration: motion.userAcceleration)
        }
        AppLogger.sensors.debug("G-force tracking started (reset=\(resetSession))")
    }

    func stopTracking() {
        motionManager.stopDeviceMotionUpdates()
        currentGForce = 0
        AppLogger.sensors.debug("G-force tracking stopped")
    }

    private func handle(userAcceleration: CMAcceleration) {
        let x = userAcceleration.x
        let y = userAcceleration.y
        let z = userAcceleration.z
        let accelerationMps2 = sqrt(x * x + y * y + z * z) * 9.81
        let rawG = accelerationMps2 / 9.81

        let meaningfulG = rawG > 0.05 ? rawG : 0
        currentGForce = (currentGForce * 0.8) + (meaningfulG * 0.2)
        if meaningfulG > maxSessionGForce {
            maxSessionGForce = meaningfulG
        }
    }
}
