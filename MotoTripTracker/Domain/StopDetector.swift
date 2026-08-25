import Foundation

/// Classifies gaps between GPS pings as moving vs stopped time.
final class StopDetector: @unchecked Sendable {
    private var lastUpdateTime: TimeInterval = 0

    /// Gaps ≤ 4 s count as continuous moving.
    private let maxMovingGapSeconds: TimeInterval = 4
    /// Gaps > 5 min are ignored (tunnel / sleep).
    private let maxValidDeltaSeconds: TimeInterval = 300

    func reset() {
        lastUpdateTime = 0
    }

    /// - Parameters:
    ///   - currentTime: location timestamp (seconds since reference date / epoch)
    ///   - onTimeUpdated: `(movingMillis, stoppedMillis)`
    func updateTimes(
        currentTime: TimeInterval,
        onTimeUpdated: (_ movingMillis: Int64, _ stoppedMillis: Int64) -> Void
    ) {
        if lastUpdateTime == 0 {
            lastUpdateTime = currentTime
            return
        }

        let timeDelta = currentTime - lastUpdateTime
        lastUpdateTime = currentTime

        let timeDeltaMs = Int64(timeDelta * 1000)
        if timeDeltaMs <= 0 || timeDelta > maxValidDeltaSeconds {
            return
        }

        if timeDelta <= maxMovingGapSeconds {
            onTimeUpdated(timeDeltaMs, 0)
        } else {
            let movingPortion: Int64 = 2000
            let stoppedPortion = timeDeltaMs - movingPortion
            onTimeUpdated(movingPortion, max(0, stoppedPortion))
        }
    }
}
