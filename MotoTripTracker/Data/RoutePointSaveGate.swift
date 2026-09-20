import Foundation

/// Decides when in-memory GPS points should be flushed to SwiftData.
/// Inserts still happen on every tick; this only throttles `ModelContext.save()`.
struct RoutePointSaveGate {
    static let maxUnsavedPoints = 5
    static let maxUnsavedSeconds: TimeInterval = 4

    private var unsavedCount = 0
    private var lastSaveTime: TimeInterval = 0

    /// Returns `true` when the caller should persist the pending batch.
    mutating func recordPoint(at time: TimeInterval) -> Bool {
        if lastSaveTime == 0 {
            lastSaveTime = time
        }
        unsavedCount += 1
        let dueToCount = unsavedCount >= Self.maxUnsavedPoints
        let dueToTime = time - lastSaveTime >= Self.maxUnsavedSeconds
        guard dueToCount || dueToTime else { return false }
        unsavedCount = 0
        lastSaveTime = time
        return true
    }

    /// Returns `true` when there is a pending batch the caller should persist now.
    mutating func consumeFlush() -> Bool {
        guard unsavedCount > 0 else { return false }
        unsavedCount = 0
        lastSaveTime = 0
        return true
    }

    mutating func reset() {
        unsavedCount = 0
        lastSaveTime = 0
    }
}
