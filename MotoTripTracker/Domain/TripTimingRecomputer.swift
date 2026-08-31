import Foundation

/// Rebuilds moving / stopped seconds from recorded route point timestamps.
/// Used to repair rides that under-counted time (sub-second GPS truncation bug).
enum TripTimingRecomputer {
    /// Gaps longer than this are treated as app kill / multi-hour pause and ignored.
    private static let maxValidDeltaSeconds: TimeInterval = 1_200
    private static let movingSpeedMps: Double = 0.1

    static func times(from points: [RoutePoint]) -> (movingSeconds: Int64, stoppedSeconds: Int64) {
        guard points.count >= 2 else { return (0, 0) }

        var movingMs: Int64 = 0
        var stoppedMs: Int64 = 0
        let ordered = points.sorted { $0.timestamp < $1.timestamp }

        for index in 1..<ordered.count {
            let previous = ordered[index - 1]
            let current = ordered[index]
            let delta = current.timestamp - previous.timestamp
            guard delta > 0, delta <= maxValidDeltaSeconds else { continue }

            let deltaMs = Int64((delta * 1000).rounded())
            if current.speedMps > movingSpeedMps {
                movingMs += deltaMs
            } else {
                stoppedMs += deltaMs
            }
        }

        return (movingMs / 1000, stoppedMs / 1000)
    }

    /// True when persisted timers are far below the GPS timeline (classic truncation symptom).
    static func looksUndercounted(
        movingSeconds: Int64,
        stoppedSeconds: Int64,
        points: [RoutePoint],
        minimumGapSeconds: Int64 = 30
    ) -> Bool {
        guard let first = points.map(\.timestamp).min(),
              let last = points.map(\.timestamp).max() else { return false }
        let span = Int64(max(0, last - first))
        let recorded = movingSeconds + stoppedSeconds
        return span - recorded >= minimumGapSeconds
    }
}
