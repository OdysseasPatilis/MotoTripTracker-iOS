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

    var effectiveLimitKmh: Int {
        autoLimitKmh ?? 50
    }

    private var lastFetchLocation: CLLocation?
    private var lastFetchTime: Date?
    private var inFlightTask: Task<Void, Never>?
    private var preferredEndpointIndex = 0
    private var cache: [String: Int?] = [:]
    private var cacheDirty = false
    private let regionPacks: [SpeedLimitRegionPack]

    private let minFetchInterval: TimeInterval = 8
    private let minFetchDistanceMeters: CLLocationDistance = 25
    private let queryRadiiMeters = [40, 80, 160, 280]
    private let gridScale = 500.0
    private let session: URLSession
    private let cacheStore: SpeedLimitCacheStore

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
        cacheStore: SpeedLimitCacheStore = SpeedLimitCacheStore(),
        regionPacks: [SpeedLimitRegionPack] = SpeedLimitRegionPackStore.bundled
    ) {
        self.session = session
        self.cacheStore = cacheStore
        self.regionPacks = regionPacks
        let loaded = cacheStore.load()
        cache = loaded.mapValues { Optional($0) }
        UserDefaults.standard.removeObject(forKey: "moto_manual_speed_limit")
        AppLogger.speedLimit.info(
            "Loaded \(loaded.count) cached speed-limit cells; \(regionPacks.count) region pack(s)"
        )
    }

    func refresh(for location: CLLocation) {
        // Bundled city pack first (offline). Empty cells and implausible pack
        // hits (e.g. 50 km/h while riding at highway speed) fall through to Overpass.
        if let hit = SpeedLimitRegionPackStore.limit(for: location, packs: regionPacks) {
            if autoLimitKmh != hit.kmh {
                autoLimitKmh = hit.kmh
                lastUpdated = Date()
                if LogThrottle.shouldLog(key: "speedLimit.pack.\(hit.pack.id)", interval: 20) {
                    AppLogger.speedLimit.debug(
                        "Region pack \(hit.pack.id, privacy: .public) → \(hit.kmh) km/h"
                    )
                }
            }
            if limitLooksPlausible(hit.kmh, for: location) {
                lastFetchLocation = location
                lastFetchTime = Date()
                return
            }
            if LogThrottle.shouldLog(key: "speedLimit.packMismatch", interval: 20) {
                AppLogger.speedLimit.info(
                    "Pack \(hit.kmh) km/h looks low vs GPS — querying Overpass"
                )
            }
        }

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

        if let cachedLimit = cache[key] ?? nil, limitLooksPlausible(cachedLimit, for: location) {
            autoLimitKmh = cachedLimit
            lastUpdated = Date()
            lastFetchLocation = location
            lastFetchTime = Date()
            AppLogger.speedLimit.debug("Cache hit key=\(key, privacy: .public) limit=\(cachedLimit)")
            return
        }

        if let nearby = nearestCachedLimit(lat: lat, lon: lon),
           limitLooksPlausible(nearby, for: location) {
            autoLimitKmh = nearby
            lastUpdated = Date()
            AppLogger.speedLimit.debug("Offline neighbour limit=\(nearby)")
        }

        inFlightTask?.cancel()
        inFlightTask = Task {
            await fetchLimit(for: location, cacheKey: key)
        }
    }

    func reset() {
        inFlightTask?.cancel()
        autoLimitKmh = nil
        lastUpdated = nil
        lastFetchLocation = nil
        lastFetchTime = nil
        isFetching = false
        cache.keys.filter { cache[$0] == nil }.forEach { cache.removeValue(forKey: $0) }
        persistCacheIfNeeded()
        AppLogger.speedLimit.debug("Speed limit service reset (kept \(self.cache.count) offline cells)")
    }

    /// True when GPS speed is not clearly above the posted limit (pack/cache may be a side street).
    private func limitLooksPlausible(_ kmh: Int, for location: CLLocation) -> Bool {
        guard location.speed >= 0 else { return true }
        return location.speed * 3.6 <= Double(kmh) + 25
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
            if let parsed = await queryNearestMaxSpeed(lat: lat, lon: lon, radiusMeters: radius) {
                resolved = parsed
                break
            }
        }

        guard !Task.isCancelled else { return }

        lastFetchLocation = location
        lastFetchTime = Date()

        if let resolved {
            cache[cacheKey] = resolved
            cacheDirty = true
            autoLimitKmh = resolved
            lastUpdated = Date()
            persistCacheIfNeeded()
            AppLogger.speedLimit.notice("Speed limit resolved → \(resolved) km/h")
        } else {
            AppLogger.speedLimit.info("No maxspeed tag found nearby")
        }
    }

    private func queryNearestMaxSpeed(lat: Double, lon: Double, radiusMeters: Int) async -> Int? {
        let query = """
        [out:json][timeout:10];
        (
          way(around:\(radiusMeters),\(lat),\(lon))["highway"];
        );
        out tags;
        """

        for (rotationIndex, endpoint) in rotatedEndpoints().enumerated() {
            if let parsed = await requestMaxSpeed(endpoint: endpoint, query: query) {
                preferredEndpointIndex = (preferredEndpointIndex + rotationIndex) % Self.endpoints.count
                return parsed
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

    private func requestMaxSpeed(endpoint: String, query: String) async -> Int? {
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
            return parseBestLimit(from: data)
        } catch {
            if !Task.isCancelled {
                AppLogger.speedLimit.warning("Overpass \(endpoint) failed: \(error.localizedDescription, privacy: .public)")
            }
            return nil
        }
    }

    private func parseBestLimit(from data: Data) -> Int? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = json["elements"] as? [[String: Any]]
        else { return nil }

        var bestLimit: Int?
        var bestPriority = Int.min
        var bestHasExplicitTag = false

        for element in elements {
            guard let tags = element["tags"] as? [String: String] else { continue }
            let highway = tags["highway"] ?? ""
            let priority = Self.highwayPriority[highway] ?? 1
            let explicit = tags["maxspeed"].flatMap { OSMMaxSpeedParser.parseKmh($0) }
            let implied = OSMMaxSpeedParser.impliedKmh(forHighway: highway)
            guard let kmh = explicit ?? implied else { continue }

            let hasExplicit = explicit != nil
            if priority > bestPriority
                || (priority == bestPriority && hasExplicit && !bestHasExplicitTag) {
                bestPriority = priority
                bestLimit = kmh
                bestHasExplicitTag = hasExplicit
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
}

#if DEBUG
extension SpeedLimitService {
    func setAutoLimitForTesting(_ kmh: Int?) {
        autoLimitKmh = kmh
        lastUpdated = Date()
    }
}
#endif
