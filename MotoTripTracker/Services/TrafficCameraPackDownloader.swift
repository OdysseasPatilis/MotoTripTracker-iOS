import CoreLocation
import Foundation
import os

enum TrafficCameraPackDownloadError: Error, Equatable {
    case emptyCSV
    case missingHeader
    case unsupportedCountry
    case httpStatus(Int)
    case emptyResponse
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

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 404 {
            throw TrafficCameraPackDownloadError.unsupportedCountry
        }
        guard (200...299).contains(status) else {
            throw TrafficCameraPackDownloadError.httpStatus(status)
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw TrafficCameraPackDownloadError.emptyResponse
        }
        return try parseCSV(text, countryCode: countryCode)
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
        self.meta = Self.loadMeta(from: metaURL) ?? [:]
    }

    func packURL(countryCode: String) -> URL {
        directory.appendingPathComponent("camera_pack_\(countryCode.uppercased()).json")
    }

    func loadPack(countryCode: String) -> (pack: TrafficCameraRegionPack, downloadedAt: Date)? {
        let cc = countryCode.uppercased()
        let url = packURL(countryCode: cc)
        guard let data = try? Data(contentsOf: url),
              let pack = try? TrafficCameraRegionPackStore.decode(data)
        else { return nil }
        lock.lock()
        let downloadedAt = meta[cc]?.downloadedAt ?? .distantPast
        lock.unlock()
        return (pack, downloadedAt)
    }

    func save(pack: TrafficCameraRegionPack, countryCode: String, downloadedAt: Date) throws {
        let cc = countryCode.uppercased()
        let data = try TrafficCameraRegionPackStore.encode(pack)
        try data.write(to: packURL(countryCode: cc), options: .atomic)
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
            try? fileManager.removeItem(at: packURL(countryCode: cc))
            meta.removeValue(forKey: cc)
        }
        persistMetaLocked()
        lock.unlock()
    }

    private func persistMetaLocked() {
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? data.write(to: metaURL, options: .atomic)
    }

    private static func loadMeta(from url: URL) -> [String: MetaEntry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: MetaEntry].self, from: data)
    }
}
