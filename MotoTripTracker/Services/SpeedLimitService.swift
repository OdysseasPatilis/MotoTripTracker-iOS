import CoreLocation
import Foundation
import os

/// Fetches road speed limits from OpenStreetMap via the Overpass API.
@Observable
@MainActor
final class SpeedLimitService {
    private(set) var autoLimitKmh: Int?
    private(set) var isFetching = false
    private(set) var lastUpdated: Date?

    /// When set, overrides the Overpass result until cleared.
    var manualOverrideKmh: Int?

    var effectiveLimitKmh: Int {
        manualOverrideKmh ?? autoLimitKmh ?? 50
    }

    var isUsingManualOverride: Bool { manualOverrideKmh != nil }
    var hasAutoLimit: Bool { autoLimitKmh != nil && manualOverrideKmh == nil }

    private var lastFetchLocation: CLLocation?
    private var lastFetchTime: Date?
    private var inFlightTask: Task<Void, Never>?

    private let minFetchInterval: TimeInterval = 20
    private let minFetchDistanceMeters: CLLocationDistance = 75
    private let searchRadiusMeters = 35

    private let session: URLSession
    private let overpassURL: URL

    init(
        session: URLSession = .shared,
        overpassURL: URL = URL(string: "https://overpass-api.de/api/interpreter")!
    ) {
        self.session = session
        self.overpassURL = overpassURL
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

        inFlightTask?.cancel()
        inFlightTask = Task {
            await fetchLimit(for: location)
        }
    }

    func clearManualOverride() {
        manualOverrideKmh = nil
        AppLogger.speedLimit.info("Manual speed limit override cleared — using auto=\(self.autoLimitKmh ?? -1) km/h")
    }

    func reset() {
        inFlightTask?.cancel()
        autoLimitKmh = nil
        manualOverrideKmh = nil
        lastUpdated = nil
        lastFetchLocation = nil
        lastFetchTime = nil
        isFetching = false
        AppLogger.speedLimit.debug("Speed limit service reset")
    }

    private func shouldFetch(for location: CLLocation) -> Bool {
        if isFetching { return false }

        let now = Date()
        if let lastFetchTime, now.timeIntervalSince(lastFetchTime) < minFetchInterval {
            if let lastFetchLocation,
               location.distance(from: lastFetchLocation) < minFetchDistanceMeters {
                return false
            }
        }
        return true
    }

    private func fetchLimit(for location: CLLocation) async {
        isFetching = true
        defer { isFetching = false }

        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        AppLogger.speedLimit.info(
            "Overpass query @ \(AppLogger.coordinate(lat, lon), privacy: .public) radius=\(self.searchRadiusMeters)m"
        )
        let query = """
        [out:json][timeout:8];
        way(around:\(searchRadiusMeters),\(lat),\(lon))["highway"]["maxspeed"];
        out tags center 1;
        """

        var request = URLRequest(url: overpassURL)
        request.httpMethod = "POST"
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "data", value: query)]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("MotoTripTracker/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12

        do {
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled else { return }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                AppLogger.speedLimit.error("Overpass HTTP error status=\(code)")
                return
            }

            let limit = try parseNearestLimit(from: data, near: location)
            guard !Task.isCancelled else { return }

            if let limit {
                autoLimitKmh = limit
                lastUpdated = Date()
                AppLogger.speedLimit.notice("Speed limit resolved → \(limit) km/h")
            } else {
                AppLogger.speedLimit.info("No maxspeed tag found nearby")
            }
            lastFetchLocation = location
            lastFetchTime = Date()
        } catch {
            if !Task.isCancelled {
                AppLogger.speedLimit.error("Overpass fetch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func parseNearestLimit(from data: Data, near location: CLLocation) throws -> Int? {
        let decoded = try JSONDecoder().decode(OverpassResponse.self, from: data)
        let candidates: [(distance: CLLocationDistance, limit: Int)] = decoded.elements.compactMap { element in
            guard let raw = element.tags?["maxspeed"],
                  let limit = OSMMaxSpeedParser.parseKmh(raw),
                  let center = element.center
            else { return nil }
            let roadPoint = CLLocation(latitude: center.lat, longitude: center.lon)
            return (location.distance(from: roadPoint), limit)
        }
        return candidates.min(by: { $0.distance < $1.distance })?.limit
    }
}

private struct OverpassResponse: Decodable {
    let elements: [OverpassElement]
}

private struct OverpassElement: Decodable {
    let tags: [String: String]?
    let center: OverpassCenter?
}

private struct OverpassCenter: Decodable {
    let lat: Double
    let lon: Double
}

#if DEBUG
extension SpeedLimitService {
    /// Test hook — inject a parsed limit without hitting the network.
    func setAutoLimitForTesting(_ kmh: Int?) {
        autoLimitKmh = kmh
        lastUpdated = Date()
    }
}
#endif
