import CoreLocation
import Foundation
import os

/// Fetches road speed limits from OpenStreetMap via Overpass mirrors, with disk cache.
@Observable
@MainActor
final class SpeedLimitService {
    private(set) var autoLimitKmh: Int?
    private(set) var isFetching = false
    private(set) var lastUpdated: Date?

    /// When set, overrides the Overpass result until cleared. Persisted across launches.
    var manualOverrideKmh: Int? {
        didSet { persistManualOverride() }
    }

    var effectiveLimitKmh: Int {
        manualOverrideKmh ?? autoLimitKmh ?? 50
    }

    var isUsingManualOverride: Bool { manualOverrideKmh != nil }
    var hasAutoLimit: Bool { autoLimitKmh != nil && manualOverrideKmh == nil }

    private var lastFetchLocation: CLLocation?
    private var lastFetchTime: Date?
    private var inFlightTask: Task<Void, Never>?
    private var preferredEndpointIndex = 0
    private var cache: [String: Int?] = [:]
    private var cacheDirty = false

    private let minFetchInterval: TimeInterval = 15
    private let minFetchDistanceMeters: CLLocationDistance = 35
    private let queryRadiiMeters = [30, 60]
    private let gridScale = 500.0
    private let session: URLSession
    private let cacheStore: SpeedLimitCacheStore
    private let manualOverrideKey = "moto_manual_speed_limit"

    private static let endpoints = [
        "https://lz4.overpass-api.de/api/interpreter",
        "https://z.overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
        "https://overpass-api.de/api/interpreter"
    ]

    private static let highwayPriority: [String: Int] = [
        "motorway": 100, "motorway_link": 95,
        "trunk": 90, "trunk_link": 85,
        "primary": 80, "primary_link": 75,
        "secondary": 70, "secondary_link": 65,
        "tertiary": 60, "tertiary_link": 55,
        "unclassified": 40, "residential": 35,
        "living_street": 30, "service": 20
    ]

    init(
        session: URLSession = .shared,
        cacheStore: SpeedLimitCacheStore = SpeedLimitCacheStore()
    ) {
        self.session = session
        self.cacheStore = cacheStore
        let loaded = cacheStore.load()
        cache = loaded.mapValues { Optional($0) }
        let stored = UserDefaults.standard.object(forKey: manualOverrideKey) as? Int
        if let stored, (30...130).contains(stored) {
            manualOverrideKmh = stored
        }
        AppLogger.speedLimit.info("Loaded \(loaded.count) cached speed-limit cells")
    }

    func refresh(for location: CLLocation) {
        guard shouldFetch(for: location) else {
            if LogThrottle.shouldLog(key: "speedLimit.throttle", interval: 30) {
                AppLogger.speedLimit.debug(
                    "Fetch skipped (throttled) @ \(AppLogger.coordinate(location.coordinate.latitude, location.coordinate.longitude), privacy: .public)"
                )
            }
            return
        }

        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let key = gridKey(lat: lat, lon: lon)

        if let cached = cache[key] {
            if let cached {
                autoLimitKmh = cached
                lastUpdated = Date()
            }
            lastFetchLocation = location
            lastFetchTime = Date()
            AppLogger.speedLimit.debug("Cache hit key=\(key, privacy: .public) limit=\(cached.map(String.init) ?? "none")")
            return
        }

        if let nearby = nearestCachedLimit(lat: lat, lon: lon) {
            autoLimitKmh = nearby
            lastUpdated = Date()
            AppLogger.speedLimit.debug("Offline neighbour limit=\(nearby)")
        }

        inFlightTask?.cancel()
        inFlightTask = Task {
            await fetchLimit(for: location, cacheKey: key)
        }
    }

    func clearManualOverride() {
        manualOverrideKmh = nil
        AppLogger.speedLimit.info("Manual speed limit override cleared — using auto=\(self.autoLimitKmh ?? -1) km/h")
    }

    func reset() {
        inFlightTask?.cancel()
        autoLimitKmh = nil
        // Keep persisted manual preference across rides (Android ThemeStore behavior).
        lastUpdated = nil
        lastFetchLocation = nil
        lastFetchTime = nil
        isFetching = false
        cache.keys.filter { cache[$0] == nil }.forEach { cache.removeValue(forKey: $0) }
        persistCacheIfNeeded()
        AppLogger.speedLimit.debug("Speed limit service reset (kept \(self.cache.count) offline cells)")
    }

    private func shouldFetch(for location: CLLocation) -> Bool {
        if isFetching { return false }
        guard let lastFetchLocation, let lastFetchTime else { return true }
        let moved = location.distance(from: lastFetchLocation) >= minFetchDistanceMeters
        let waited = Date().timeIntervalSince(lastFetchTime) >= minFetchInterval
        return moved || waited
    }

    private func fetchLimit(for location: CLLocation, cacheKey: String) async {
        isFetching = true
        defer { isFetching = false }

        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        AppLogger.speedLimit.info(
            "Overpass query @ \(AppLogger.coordinate(lat, lon), privacy: .public)"
        )

        var resolved: Int?
        for radius in queryRadiiMeters {
            if let raw = await queryNearestMaxSpeed(lat: lat, lon: lon, radiusMeters: radius),
               let parsed = OSMMaxSpeedParser.parseKmh(raw) {
                resolved = parsed
                break
            }
        }

        guard !Task.isCancelled else { return }

        cache[cacheKey] = resolved
        cacheDirty = true
        lastFetchLocation = location
        lastFetchTime = Date()

        if let resolved {
            autoLimitKmh = resolved
            lastUpdated = Date()
            persistCacheIfNeeded()
            AppLogger.speedLimit.notice("Speed limit resolved → \(resolved) km/h")
        } else {
            AppLogger.speedLimit.info("No maxspeed tag found nearby")
        }
    }

    private func queryNearestMaxSpeed(lat: Double, lon: Double, radiusMeters: Int) async -> String? {
        let query = """
        [out:json][timeout:10];
        (
          way(around:\(radiusMeters),\(lat),\(lon))["highway"]["maxspeed"];
        );
        out tags;
        """

        for (rotationIndex, endpoint) in rotatedEndpoints().enumerated() {
            if let raw = await requestMaxSpeed(endpoint: endpoint, query: query) {
                preferredEndpointIndex = (preferredEndpointIndex + rotationIndex) % Self.endpoints.count
                return raw
            }
        }
        AppLogger.speedLimit.error("All Overpass mirrors failed @ \(AppLogger.coordinate(lat, lon), privacy: .public)")
        return nil
    }

    private func rotatedEndpoints() -> [String] {
        var list = Self.endpoints
        if preferredEndpointIndex < list.count {
            let preferred = list.remove(at: preferredEndpointIndex)
            list.insert(preferred, at: 0)
        }
        return list
    }

    private func requestMaxSpeed(endpoint: String, query: String) async -> String? {
        guard let url = URL(string: endpoint) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "data", value: query)]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("MotoTripTracker/1.0 (iOS; motorcycle trip tracker)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                AppLogger.speedLimit.warning("Overpass HTTP \(code) from \(endpoint)")
                return nil
            }
            return parseBestMaxSpeed(from: data)
        } catch {
            if !Task.isCancelled {
                AppLogger.speedLimit.warning("Overpass \(endpoint) failed: \(error.localizedDescription, privacy: .public)")
            }
            return nil
        }
    }

    private func parseBestMaxSpeed(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = json["elements"] as? [[String: Any]]
        else { return nil }

        var bestLimit: String?
        var bestPriority = Int.min

        for element in elements {
            guard let tags = element["tags"] as? [String: String],
                  let maxspeed = tags["maxspeed"], !maxspeed.isEmpty
            else { continue }
            let highway = tags["highway"] ?? ""
            let priority = Self.highwayPriority[highway] ?? 1
            if priority >= bestPriority {
                bestPriority = priority
                bestLimit = maxspeed
            }
        }
        return bestLimit
    }

    private func nearestCachedLimit(lat: Double, lon: Double) -> Int? {
        let latCell = Int64((lat * gridScale).rounded(.towardZero))
        let lngCell = Int64((lon * gridScale).rounded(.towardZero))
        for dLat in -1...1 {
            for dLng in -1...1 {
                if dLat == 0, dLng == 0 { continue }
                let key = "\(latCell + Int64(dLat))_\(lngCell + Int64(dLng))"
                if let value = cache[key] ?? nil { return value }
            }
        }
        return nil
    }

    private func gridKey(lat: Double, lon: Double) -> String {
        let latCell = Int64((lat * gridScale).rounded(.towardZero))
        let lngCell = Int64((lon * gridScale).rounded(.towardZero))
        return "\(latCell)_\(lngCell)"
    }

    private func persistCacheIfNeeded() {
        guard cacheDirty else { return }
        cacheStore.save(cache)
        cacheDirty = false
    }

    private func persistManualOverride() {
        if let manualOverrideKmh {
            UserDefaults.standard.set(manualOverrideKmh, forKey: manualOverrideKey)
        } else {
            UserDefaults.standard.removeObject(forKey: manualOverrideKey)
        }
    }
}

#if DEBUG
extension SpeedLimitService {
    func setAutoLimitForTesting(_ kmh: Int?) {
        autoLimitKmh = kmh
        lastUpdated = Date()
    }
}
#endif
