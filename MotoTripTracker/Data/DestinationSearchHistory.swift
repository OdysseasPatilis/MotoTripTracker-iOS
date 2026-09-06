import Foundation

struct DestinationHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var subtitle: String
    var latitude: Double
    var longitude: Double
    var timestamp: TimeInterval
}

enum DestinationSearchHistory {
    static let storageKey = "moto.nav.destinationHistory"
    static let maxEntries = 20
    /// ~25 m — treat as the same place for dedupe.
    private static let dedupeDegrees = 0.00025

    static func all(defaults: UserDefaults = .standard) -> [DestinationHistoryEntry] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([DestinationHistoryEntry].self, from: data)) ?? []
    }

    static func add(
        name: String,
        subtitle: String,
        latitude: Double,
        longitude: Double,
        defaults: UserDefaults = .standard
    ) {
        var items = all(defaults: defaults)
        items.removeAll {
            abs($0.latitude - latitude) < dedupeDegrees
                && abs($0.longitude - longitude) < dedupeDegrees
        }
        let entry = DestinationHistoryEntry(
            id: UUID(),
            name: name,
            subtitle: subtitle,
            latitude: latitude,
            longitude: longitude,
            timestamp: Date().timeIntervalSince1970
        )
        items.insert(entry, at: 0)
        if items.count > maxEntries {
            items = Array(items.prefix(maxEntries))
        }
        save(items, defaults: defaults)
    }

    static func remove(id: UUID, defaults: UserDefaults = .standard) {
        var items = all(defaults: defaults)
        items.removeAll { $0.id == id }
        save(items, defaults: defaults)
    }

    private static func save(_ items: [DestinationHistoryEntry], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
