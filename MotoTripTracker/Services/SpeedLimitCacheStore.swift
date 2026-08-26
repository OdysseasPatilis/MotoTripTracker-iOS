import Foundation

/// Persists grid-keyed speed limits so rides can reuse nearby values offline.
final class SpeedLimitCacheStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "moto_speed_limit_grid_cache"
    private let maxEntries = 2_000

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [String: Int] {
        guard let raw = defaults.dictionary(forKey: key) as? [String: Int] else { return [:] }
        return raw.filter { $0.value >= 5 && $0.value <= 200 }
    }

    func save(_ cache: [String: Int?]) {
        let entries = cache
            .compactMap { key, value -> (String, Int)? in
                guard let value else { return nil }
                return (key, value)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(maxEntries)
        var dict: [String: Int] = [:]
        for (key, value) in entries {
            dict[key] = value
        }
        defaults.set(dict, forKey: key)
    }
}
