import Foundation

/// Classifies elapsed time between GPS pings as moving vs stopped using speed.
final class StopDetector: @unchecked Sendable {
    private var lastUpdateTime: TimeInterval = 0

    /// Gaps > 20 min are ignored (app kill / multi-hour pause without GPS).
    /// Shorter gaps (tunnels, brief background) still count toward moving/stopped time.
    private let maxValidDeltaSeconds: TimeInterval = 1_200
    /// Gaps longer than this likely mean GPS paused while locked — use last motion state.
    private let longGapSeconds: TimeInterval = 45

    func reset() {
        lastUpdateTime = 0
    }

    /// - Parameters:
    ///   - currentTime: location timestamp (seconds since epoch)
    ///   - isMoving: `true` when filtered speed indicates real motion
    ///   - lastWasMoving: previous tick's motion — used to classify long GPS gaps after background
    ///   - onTimeUpdated: `(movingMillis, stoppedMillis)`
    func updateTimes(
        currentTime: TimeInterval,
        isMoving: Bool,
        lastWasMoving: Bool = false,
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

        let effectiveMoving = timeDelta > longGapSeconds ? lastWasMoving : isMoving
        if effectiveMoving {
            onTimeUpdated(timeDeltaMs, 0)
        } else {
            onTimeUpdated(0, timeDeltaMs)
        }
    }
}
