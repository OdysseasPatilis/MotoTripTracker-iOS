import Foundation

final class ElevationSmoother: @unchecked Sendable {
    private let alpha: Double
    private var smoothedAltitude: Double?
    private var referenceAltitude: Double?

    init(alpha: Double = 0.15) {
        self.alpha = alpha
    }

    func calculateGain(rawAltitude: Double) -> Double {
        let currentSmoothed: Double
        if let smoothedAltitude {
            currentSmoothed = (alpha * rawAltitude) + ((1 - alpha) * smoothedAltitude)
        } else {
            currentSmoothed = rawAltitude
        }
        smoothedAltitude = currentSmoothed

        guard let reference = referenceAltitude else {
            referenceAltitude = currentSmoothed
            return 0
        }

        let diff = currentSmoothed - reference
        if diff > 2.5 {
            referenceAltitude = currentSmoothed
            return diff
        }
        if diff < -2.5 {
            referenceAltitude = currentSmoothed
            return 0
        }
        return 0
    }
}
