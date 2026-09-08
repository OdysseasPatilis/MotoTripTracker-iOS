import CoreLocation
import Foundation
import UIKit
import os

/// Loads traffic cameras from a bundled pack + Overpass, and warns while riding.
@Observable
@MainActor
final class TrafficCameraService {
    private(set) var nearbyCameras: [TrafficCamera] = []
    private(set) var activeAlert: TrafficCameraAlert?
    private(set) var isFetching = false

    private let regionPacks: [TrafficCameraRegionPack]
    private let session: URLSession
    private let voice = NavigationVoicePrompt()
    private var cacheByID: [String: CachedEntry] = [:]
    private var liveByID: [String: TrafficCamera] = [:]
    private var announcedIDs: Set<String> = []
    private var lastFetchLocation: CLLocation?
    private var lastFetchTime: Date?
    private var preferredEndpointIndex = 0
    private var inFlightTask: Task<Void, Never>?
    private var alertClearTask: Task<Void, Never>?

    private let nearbyRadiusMeters: CLLocationDistance = 1_500
    private let overpassRadiusMeters = 1_200
    private let minFetchInterval: TimeInterval = 45
    private let minFetchDistanceMeters: CLLocationDistance = 400
    private let clearApproachExtraMeters: CLLocationDistance = 80
    private let alertBannerSeconds: TimeInterval = 6
    private let cacheTTL: TimeInterval = 30 * 24 * 60 * 60
    private let maxCacheEntries = 2_000
    private let cacheDefaultsKey = "moto_traffic_camera_cache_v1"

    private static let endpoints = [
        "https://lz4.overpass-api.de/api/interpreter",
        "https://z.overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
        "https://overpass-api.de/api/interpreter"
    ]

    init(
        session: URLSession = .shared,
        regionPacks: [TrafficCameraRegionPack] = TrafficCameraRegionPackStore.bundled
    ) {
        self.session = session
        self.regionPacks = regionPacks
        cacheByID = Self.loadCache(key: cacheDefaultsKey)
        AppLogger.trafficCamera.info(
            "TrafficCameraService ready packs=\(regionPacks.count) cache=\(self.cacheByID.count)"
        )
    }

    func refresh(for location: CLLocation) {
        publishNearby(at: location)
        evaluateAlert(at: location)

        guard shouldFetch(for: location) else { return }
        inFlightTask?.cancel()
        inFlightTask = Task {
            await fetchOverpass(around: location)
        }
    }

    func reset() {
        inFlightTask?.cancel()
        inFlightTask = nil
        alertClearTask?.cancel()
        alertClearTask = nil
        activeAlert = nil
        announcedIDs.removeAll()
        nearbyCameras = []
        // Keep pack + disk cache + last live results for the next ride.
        AppLogger.trafficCamera.notice("Traffic camera alerts reset")
    }

    // MARK: - Candidates

    private func allKnownCameras() -> [TrafficCamera] {
        var byID: [String: TrafficCamera] = [:]
        for pack in regionPacks {
            for camera in pack.cameras {
                byID[camera.id] = camera
            }
        }
        for entry in cacheByID.values {
            byID[entry.camera.id] = entry.camera
        }
        for camera in liveByID.values {
            byID[camera.id] = camera
        }
        return Array(byID.values)
    }

    private func publishNearby(at location: CLLocation) {
        nearbyCameras = allKnownCameras()
            .filter { location.distance(from: $0.location) <= nearbyRadiusMeters }
            .sorted { location.distance(from: $0.location) < location.distance(from: $1.location) }
    }

    private func evaluateAlert(at location: CLLocation) {
        let warn = TrafficCameraLogic.warnDistanceMeters(speedMps: location.speed)

        for id in announcedIDs {
            guard let camera = allKnownCameras().first(where: { $0.id == id }) else {
                announcedIDs.remove(id)
                continue
            }
            if location.distance(from: camera.location) > warn + clearApproachExtraMeters {
                announcedIDs.remove(id)
            }
        }

        let course = location.course
        let ahead = allKnownCameras().compactMap { camera -> (TrafficCamera, CLLocationDistance)? in
            let distance = location.distance(from: camera.location)
            guard distance <= warn else { return nil }
            let bearing = TrafficCameraLogic.bearingDegrees(
                from: location.coordinate,
                to: camera.coordinate
            )
            guard TrafficCameraLogic.isAhead(
                riderHeadingDegrees: course,
                bearingToCameraDegrees: bearing,
                speedMps: location.speed
            ) else { return nil }
            return (camera, distance)
        }
        .sorted { $0.1 < $1.1 }

        guard let (camera, distance) = ahead.first else { return }

        if announcedIDs.contains(camera.id) {
            if activeAlert?.camera.id == camera.id {
                activeAlert = TrafficCameraAlert(camera: camera, distanceMeters: distance)
            }
            return
        }

        announcedIDs.insert(camera.id)
        let alert = TrafficCameraAlert(camera: camera, distanceMeters: distance)
        activeAlert = alert
        voice.speak(camera.speakText)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        AppLogger.trafficCamera.notice(
            "Camera alert \(camera.kind.rawValue, privacy: .public) \(Int(distance))m id=\(camera.id, privacy: .public)"
        )
        scheduleAlertClear()
    }

    private func scheduleAlertClear() {
        alertClearTask?.cancel()
        alertClearTask = Task {
            try? await Task.sleep(for: .seconds(alertBannerSeconds))
            guard !Task.isCancelled else { return }
            activeAlert = nil
        }
    }

    // MARK: - Overpass

    private func shouldFetch(for location: CLLocation) -> Bool {
        if isFetching { return false }
        guard let lastFetchLocation, let lastFetchTime else { return true }
        let moved = location.distance(from: lastFetchLocation) >= minFetchDistanceMeters
        let waited = Date().timeIntervalSince(lastFetchTime) >= minFetchInterval
        return moved || waited
    }

    private func fetchOverpass(around location: CLLocation) async {
        isFetching = true
        defer { isFetching = false }

        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let query = """
        [out:json][timeout:15];
        (
          node(around:\(overpassRadiusMeters),\(lat),\(lon))["highway"="speed_camera"];
          way(around:\(overpassRadiusMeters),\(lat),\(lon))["highway"="speed_camera"];
          node(around:\(overpassRadiusMeters),\(lat),\(lon))["enforcement"="maxspeed"];
          way(around:\(overpassRadiusMeters),\(lat),\(lon))["enforcement"="maxspeed"];
          node(around:\(overpassRadiusMeters),\(lat),\(lon))["enforcement"="traffic_signals"];
          way(around:\(overpassRadiusMeters),\(lat),\(lon))["enforcement"="traffic_signals"];
        );
        out center tags;
        """

        guard let cameras = await queryCameras(query: query) else {
            AppLogger.trafficCamera.warning(
                "Overpass camera fetch failed @ \(AppLogger.coordinate(lat, lon), privacy: .public)"
            )
            lastFetchLocation = location
            lastFetchTime = Date()
            return
        }

        lastFetchLocation = location
        lastFetchTime = Date()

        for camera in cameras {
            liveByID[camera.id] = camera
            cacheByID[camera.id] = CachedEntry(camera: camera, savedAt: Date())
        }
        pruneAndPersistCache()
        publishNearby(at: location)
        evaluateAlert(at: location)
        AppLogger.trafficCamera.info("Overpass cameras +\(cameras.count) live=\(self.liveByID.count)")
    }

    private func queryCameras(query: String) async -> [TrafficCamera]? {
        for (rotationIndex, endpoint) in rotatedEndpoints().enumerated() {
            if let cameras = await requestCameras(endpoint: endpoint, query: query) {
                preferredEndpointIndex = (preferredEndpointIndex + rotationIndex) % Self.endpoints.count
                return cameras
            }
        }
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

    private func requestCameras(endpoint: String, query: String) async -> [TrafficCamera]? {
        guard let url = URL(string: endpoint) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "data", value: query)]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("MotoTripTracker/1.0 (iOS; motorcycle trip tracker)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 18

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                AppLogger.trafficCamera.warning("Overpass HTTP \(code) from \(endpoint)")
                return nil
            }
            return Self.parseOverpassCameras(from: data)
        } catch {
            if !Task.isCancelled {
                AppLogger.trafficCamera.warning(
                    "Overpass \(endpoint) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            return nil
        }
    }

    nonisolated static func parseOverpassCameras(from data: Data) -> [TrafficCamera] {
        struct OverpassResponse: Decodable {
            let elements: [Element]
            struct Element: Decodable {
                let type: String
                let id: Int64
                let lat: Double?
                let lon: Double?
                let center: Center?
                let tags: [String: String]?
                struct Center: Decodable {
                    let lat: Double
                    let lon: Double
                }
            }
        }

        guard let decoded = try? JSONDecoder().decode(OverpassResponse.self, from: data) else {
            return []
        }

        return decoded.elements.compactMap { element in
            let tags = element.tags ?? [:]
            guard let kind = TrafficCameraLogic.kind(fromOSMTags: tags) else { return nil }
            let lat = element.lat ?? element.center?.lat
            let lon = element.lon ?? element.center?.lon
            guard let lat, let lon, lat.isFinite, lon.isFinite else { return nil }
            return TrafficCamera(
                id: "osm:\(element.type)/\(element.id)",
                latitude: lat,
                longitude: lon,
                kind: kind
            )
        }
    }

    // MARK: - Disk cache

    private struct CachedEntry: Codable {
        let camera: TrafficCamera
        let savedAt: Date
    }

    private func pruneAndPersistCache() {
        let cutoff = Date().addingTimeInterval(-cacheTTL)
        cacheByID = cacheByID.filter { $0.value.savedAt >= cutoff }
        if cacheByID.count > maxCacheEntries {
            let sorted = cacheByID.values.sorted { $0.savedAt > $1.savedAt }
            cacheByID = Dictionary(
                uniqueKeysWithValues: sorted.prefix(maxCacheEntries).map { ($0.camera.id, $0) }
            )
        }
        if let data = try? JSONEncoder().encode(Array(cacheByID.values)) {
            UserDefaults.standard.set(data, forKey: cacheDefaultsKey)
        }
    }

    private static func loadCache(key: String) -> [String: CachedEntry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([CachedEntry].self, from: data)
        else { return [:] }
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        return Dictionary(
            uniqueKeysWithValues: entries
                .filter { $0.savedAt >= cutoff }
                .map { ($0.camera.id, $0) }
        )
    }
}
