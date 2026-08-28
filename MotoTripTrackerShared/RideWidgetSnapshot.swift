import Foundation

/// Snapshot of completed-ride stats for Home Screen widgets.
/// Written by the app into the App Group; read by the widget extension.
nonisolated struct RideWidgetSnapshot: Codable, Hashable, Sendable {
    var lastRideTitle: String?
    var lastRideDistanceKm: Double?
    var lastRideMaxSpeedKmh: Double?
    var lastRideCornerCount: Int?
    var lastRideDate: Date?

    var weekRideCount: Int
    var weekDistanceKm: Double
    var weekMaxSpeedKmh: Double
    var weekCornerCount: Int

    var updatedAt: Date

    static let empty = RideWidgetSnapshot(
        lastRideTitle: nil,
        lastRideDistanceKm: nil,
        lastRideMaxSpeedKmh: nil,
        lastRideCornerCount: nil,
        lastRideDate: nil,
        weekRideCount: 0,
        weekDistanceKm: 0,
        weekMaxSpeedKmh: 0,
        weekCornerCount: 0,
        updatedAt: Date()
    )

    private static let storageKey = "moto.widget.snapshot"

    static func load() -> RideWidgetSnapshot {
        guard let data = AppGroup.defaults.data(forKey: storageKey),
              let snapshot = try? JSONDecoder().decode(RideWidgetSnapshot.self, from: data) else {
            return .empty
        }
        return snapshot
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        AppGroup.defaults.set(data, forKey: Self.storageKey)
    }
}
