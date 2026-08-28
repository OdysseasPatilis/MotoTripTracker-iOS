import ActivityKit
import Foundation
import os

/// Owns the in-progress ride Live Activity (Lock Screen + Dynamic Island).
@MainActor
final class RideLiveActivityController {
    static let shared = RideLiveActivityController()

    private var activity: Activity<RideActivityAttributes>?
    private var lastUpdate: Date = .distantPast
    private let minUpdateInterval: TimeInterval = 1.0

    private init() {}

    func start(startedAt: Date = Date()) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            AppLogger.app.info("Live Activities disabled by user/system — skipping start")
            return
        }

        // End any stale activities from a previous launch.
        for existing in Activity<RideActivityAttributes>.activities {
            Task { await existing.end(nil, dismissalPolicy: .immediate) }
        }

        let attributes = RideActivityAttributes(startedAt: startedAt)
        let state = RideActivityAttributes.ContentState(
            speedKmh: 0,
            speedLimitKmh: 50,
            distanceKm: 0,
            movingTimeSeconds: 0,
            isPaused: false,
            isOverLimit: false,
            navigationSummary: ""
        )

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
            lastUpdate = Date()
            AppLogger.app.notice("Live Activity started")
        } catch {
            AppLogger.app.error("Live Activity start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func update(
        speedKmh: Double,
        speedLimitKmh: Int,
        distanceKm: Double,
        movingTimeSeconds: Int64,
        isPaused: Bool,
        navigationSummary: String,
        force: Bool = false
    ) {
        guard let activity else { return }
        let now = Date()
        if !force, now.timeIntervalSince(lastUpdate) < minUpdateInterval { return }
        lastUpdate = now

        let speed = Int(speedKmh.rounded())
        let state = RideActivityAttributes.ContentState(
            speedKmh: speed,
            speedLimitKmh: speedLimitKmh,
            distanceKm: distanceKm,
            movingTimeSeconds: movingTimeSeconds,
            isPaused: isPaused,
            isOverLimit: !isPaused && speed > speedLimitKmh,
            navigationSummary: navigationSummary
        )

        Task {
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
            AppLogger.app.notice("Live Activity ended")
        }
    }
}
