import Foundation
import os
import WidgetKit

/// Publishes completed-ride aggregates into the App Group for Home Screen widgets.
enum RideWidgetSnapshotPublisher {
    @MainActor
    static func publish(from repository: TripRepository) {
        let trips = repository.allTrips()
        let calendar = Calendar.current
        let now = Date()

        let weekTrips = trips.filter { trip in
            calendar.isDate(
                Date(timeIntervalSince1970: trip.startTime),
                equalTo: now,
                toGranularity: .weekOfYear
            )
        }

        let last = trips.first
        var snapshot = RideWidgetSnapshot.empty
        snapshot.lastRideTitle = last?.displayTitle
        snapshot.lastRideDistanceKm = last.map { $0.distanceMeters / 1000 }
        snapshot.lastRideMaxSpeedKmh = last?.maxSpeed
        snapshot.lastRideCornerCount = last?.cornerCount
        snapshot.lastRideDate = last.map { Date(timeIntervalSince1970: $0.startTime) }

        snapshot.weekRideCount = weekTrips.count
        snapshot.weekDistanceKm = weekTrips.reduce(0) { $0 + $1.distanceMeters } / 1000
        snapshot.weekMaxSpeedKmh = weekTrips.map(\.maxSpeed).max() ?? 0
        snapshot.weekCornerCount = weekTrips.reduce(0) { $0 + $1.cornerCount }
        snapshot.updatedAt = now
        if UserDefaults(suiteName: AppGroup.identifier) == nil {
            AppLogger.app.error("Widget snapshot App Group unavailable — wrote standard UserDefaults")
        }
        if snapshot.save() {
            AppLogger.app.notice(
                "Widget snapshot saved rides=\(trips.count) week=\(snapshot.weekRideCount) dist=\(snapshot.weekDistanceKm, format: .fixed(precision: 1))km"
            )
        } else {
            AppLogger.app.error("Widget snapshot encode failed")
        }

        WidgetCenter.shared.reloadAllTimelines()
    }
}
