import CoreLocation
import Foundation
import os

enum TrafficCameraPackDownloadError: Error, Equatable, LocalizedError {
    case emptyCSV
    case missingHeader
    case unsupportedCountry
    case httpStatus(Int)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .emptyCSV:
            return "empty CSV"
        case .missingHeader:
            return "CSV missing id/latitude/longitude"
        case .unsupportedCountry:
            return "unsupported country"
        case .httpStatus(let code):
            return "HTTP \(code)"
        case .emptyResponse:
            return "empty response"
        }
    }
}

/// Fetches and parses speedcams.world country CSVs into `TrafficCameraRegionPack`s.
enum TrafficCameraPackDownloader {
    static func csvURL(countryCode: String) -> URL {
        let cc = countryCode.lowercased()
        return URL(string: "https://speedcams.world/downloads/\(cc)/\(cc)-all.csv")!
    }

    static func parseCSV(_ text: String, countryCode: String) throws -> TrafficCameraRegionPack {
        let cc = countryCode.uppercased()
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard let headerLine = lines.first else { throw TrafficCameraPackDownloadError.emptyCSV }
        let headers = parseCSVLine(headerLine).map { $0.lowercased() }
        guard let idIdx = headers.firstIndex(of: "id"),
              let latIdx = headers.firstIndex(of: "latitude"),
              let lonIdx = headers.firstIndex(of: "longitude")
        else { throw TrafficCameraPackDownloadError.missingHeader }

        var cameras: [TrafficCamera] = []
        var minLat = 90.0
        var maxLat = -90.0
        var minLon = 180.0
        var maxLon = -180.0

        for line in lines.dropFirst() {
            let cols = parseCSVLine(line)
            let needed = max(idIdx, latIdx, lonIdx)
            guard cols.count > needed else { continue }
            let rawID = cols[idIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawID.isEmpty,
                  let lat = Double(cols[latIdx]),
                  let lon = Double(cols[lonIdx]),
                  lat.isFinite, lon.isFinite,
                  abs(lat) <= 90, abs(lon) <= 180
            else { continue }

            cameras.append(
                TrafficCamera(
                    id: "osm:node/\(rawID)",
                    latitude: lat,
                    longitude: lon,
                    kind: .speed
                )
            )
            minLat = min(minLat, lat)
            maxLat = max(maxLat, lat)
            minLon = min(minLon, lon)
            maxLon = max(maxLon, lon)
        }

        if cameras.isEmpty {
            minLat = 0
            maxLat = 0
            minLon = 0
            maxLon = 0
        }

        return TrafficCameraRegionPack(
            id: "country_\(cc)",
            name: "Country \(cc) traffic cameras",
            version: 1,
            south: minLat,
            west: minLon,
            north: maxLat,
            east: maxLon,
            cameras: cameras
        )
    }

    static func parseCSVLine(_ line: String) -> [String] {
        line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }

    static func download(
        countryCode: String,
        session: URLSession
    ) async throws -> TrafficCameraRegionPack {
        let url = csvURL(countryCode: countryCode)
        var request = URLRequest(url: url)
        request.setValue(
            "MotoTripTracker/1.0 (iOS; motorcycle trip tracker)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/csv", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 45

        let cc = countryCode.uppercased()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            AppLogger.trafficCamera.warning(
                "Camera pack request failed \(cc, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 404 {
            AppLogger.trafficCamera.info("Camera pack HTTP 404 for \(cc, privacy: .public)")
            throw TrafficCameraPackDownloadError.unsupportedCountry
        }
        guard (200...299).contains(status) else {
            AppLogger.trafficCamera.warning("Camera pack HTTP \(status) for \(cc, privacy: .public)")
            throw TrafficCameraPackDownloadError.httpStatus(status)
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            AppLogger.trafficCamera.warning("Camera pack empty response for \(cc, privacy: .public)")
            throw TrafficCameraPackDownloadError.emptyResponse
        }
        do {
            return try parseCSV(text, countryCode: countryCode)
        } catch {
            AppLogger.trafficCamera.warning(
                "Camera pack CSV parse failed \(cc, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }
}

/// On-disk country packs + meta (TTL, unsupported cooldown, LRU).
final class TrafficCameraPackStore: @unchecked Sendable {
    struct MetaEntry: Codable, Equatable {
        var downloadedAt: Date?
        var lastUsedAt: Date?
        var unsupportedUntil: Date?
    }

    static let defaultTTL: TimeInterval = 30 * 24 * 60 * 60
    static let defaultUnsupportedCooldown: TimeInterval = 24 * 60 * 60
    static let defaultMaxCountries = 10

    private let directory: URL
    private let fileManager: FileManager
    private let metaURL: URL
    private var meta: [String: MetaEntry]
    private let lock = NSLock()

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.directory = base.appendingPathComponent("CameraPacks", isDirectory: true)
        }
        self.metaURL = self.directory.appendingPathComponent("camera_pack_meta.json")
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
        self.meta = Self.loadMeta(from: metaURL, fileManager: fileManager) ?? [:]
    }

    func packURL(countryCode: String) -> URL {
        directory.appendingPathComponent("camera_pack_\(countryCode.uppercased()).json")
    }

    func loadPack(countryCode: String) -> (pack: TrafficCameraRegionPack, downloadedAt: Date)? {
        let cc = countryCode.uppercased()
        let url = packURL(countryCode: cc)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let pack = try TrafficCameraRegionPackStore.decode(data)
            lock.lock()
            let downloadedAt = meta[cc]?.downloadedAt ?? .distantPast
            lock.unlock()
            return (pack, downloadedAt)
        } catch {
            AppLogger.trafficCamera.warning(
                "Camera pack disk read failed \(cc, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    func save(pack: TrafficCameraRegionPack, countryCode: String, downloadedAt: Date) throws {
        let cc = countryCode.uppercased()
        let data = try TrafficCameraRegionPackStore.encode(pack)
        do {
            try data.write(to: packURL(countryCode: cc), options: .atomic)
        } catch {
            AppLogger.trafficCamera.error(
                "Camera pack save failed \(cc, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
        lock.lock()
        var entry = meta[cc] ?? MetaEntry()
        entry.downloadedAt = downloadedAt
        entry.lastUsedAt = downloadedAt
        entry.unsupportedUntil = nil
        meta[cc] = entry
        persistMetaLocked()
        lock.unlock()
        evictIfNeeded(maxCountries: Self.defaultMaxCountries)
    }

    func touch(countryCode: String, at date: Date = Date()) {
        let cc = countryCode.uppercased()
        lock.lock()
        var entry = meta[cc] ?? MetaEntry()
        entry.lastUsedAt = date
        meta[cc] = entry
        persistMetaLocked()
        lock.unlock()
    }

    func isFresh(
        countryCode: String,
        now: Date = Date(),
        ttl: TimeInterval = TrafficCameraPackStore.defaultTTL
    ) -> Bool {
        let cc = countryCode.uppercased()
        lock.lock()
        let downloadedAt = meta[cc]?.downloadedAt
        lock.unlock()
        guard let downloadedAt else { return false }
        return now.timeIntervalSince(downloadedAt) < ttl
    }

    func markUnsupported(
        countryCode: String,
        at date: Date = Date(),
        cooldown: TimeInterval = TrafficCameraPackStore.defaultUnsupportedCooldown
    ) {
        let cc = countryCode.uppercased()
        lock.lock()
        var entry = meta[cc] ?? MetaEntry()
        entry.unsupportedUntil = date.addingTimeInterval(cooldown)
        meta[cc] = entry
        persistMetaLocked()
        lock.unlock()
    }

    func isUnsupported(countryCode: String, now: Date = Date()) -> Bool {
        let cc = countryCode.uppercased()
        lock.lock()
        let until = meta[cc]?.unsupportedUntil
        lock.unlock()
        guard let until else { return false }
        return now < until
    }

    func loadAllPacks() -> [String: TrafficCameraRegionPack] {
        lock.lock()
        let codes = Array(meta.keys)
        lock.unlock()
        var result: [String: TrafficCameraRegionPack] = [:]
        for cc in codes {
            if let loaded = loadPack(countryCode: cc) {
                result[cc] = loaded.pack
            }
        }
        return result
    }

    func evictIfNeeded(maxCountries: Int = TrafficCameraPackStore.defaultMaxCountries) {
        lock.lock()
        let sorted = meta
            .filter { $0.value.downloadedAt != nil }
            .sorted { ($0.value.lastUsedAt ?? .distantPast) < ($1.value.lastUsedAt ?? .distantPast) }
        guard sorted.count > maxCountries else {
            lock.unlock()
            return
        }
        let toRemove = sorted.prefix(sorted.count - maxCountries)
        for (cc, _) in toRemove {
            do {
                try fileManager.removeItem(at: packURL(countryCode: cc))
            } catch {
                AppLogger.trafficCamera.warning(
                    "Camera pack evict failed \(cc, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
            meta.removeValue(forKey: cc)
        }
        persistMetaLocked()
        lock.unlock()
        AppLogger.trafficCamera.info("Evicted \(toRemove.count) camera pack(s)")
    }

    private func persistMetaLocked() {
        guard let data = try? JSONEncoder().encode(meta) else {
            AppLogger.trafficCamera.error("Camera pack meta encode failed")
            return
        }
        do {
            try data.write(to: metaURL, options: .atomic)
        } catch {
            AppLogger.trafficCamera.error(
                "Camera pack meta write failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func loadMeta(from url: URL, fileManager: FileManager) -> [String: MetaEntry]? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([String: MetaEntry].self, from: data)
        } catch {
            AppLogger.trafficCamera.warning(
                "Camera pack meta unreadable: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}
