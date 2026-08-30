import CoreLocation
import Foundation
import os

/// Bundled offline speed-limit grid for a geographic region (e.g. Greater Athens).
struct SpeedLimitRegionPack: Sendable {
    let id: String
    let name: String
    let version: Int
    let gridScale: Double
    let south: Double
    let west: Double
    let north: Double
    let east: Double
    let cells: [String: Int]

    func contains(latitude: Double, longitude: Double) -> Bool {
        latitude >= south && latitude <= north && longitude >= west && longitude <= east
    }

    func contains(_ location: CLLocation) -> Bool {
        contains(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
    }

    /// Exact grid cell, then nearby cells (~2 × ~222 m) so GPS jitter still hits the pack.
    /// Keep the radius small so a miss can fall through to live Overpass instead of a distant street.
    func limit(for location: CLLocation, neighbourCells: Int = 2) -> Int? {
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        guard contains(latitude: lat, longitude: lon) else { return nil }

        let latCell = Int64((lat * gridScale).rounded(.towardZero))
        let lngCell = Int64((lon * gridScale).rounded(.towardZero))
        let key = "\(latCell)_\(lngCell)"
        if let value = cells[key] { return value }

        guard neighbourCells >= 1 else { return nil }
        let radius = neighbourCells
        for ring in 1...radius {
            for dLat in -ring...ring {
                for dLng in -ring...ring {
                    if max(abs(dLat), abs(dLng)) != ring { continue }
                    let neighbour = "\(latCell + Int64(dLat))_\(lngCell + Int64(dLng))"
                    if let value = cells[neighbour] { return value }
                }
            }
        }
        return nil
    }
}

enum SpeedLimitRegionPackStore {
    /// Bundled packs shipped with the app. First matching bbox wins.
    static let bundled: [SpeedLimitRegionPack] = {
        ["athens_speed_limits"].compactMap { loadBundled(named: $0) }
    }()

    static func loadBundled(named resource: String, bundle: Bundle? = nil) -> SpeedLimitRegionPack? {
        let url: URL?
        if let bundle {
            url = bundle.url(forResource: resource, withExtension: "json")
        } else {
            url = Self.resourceURL(named: resource, extension: "json")
        }
        guard let url else {
            AppLogger.speedLimit.error("Missing bundled speed-limit pack \(resource).json")
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let pack = try decode(data)
            AppLogger.speedLimit.info(
                "Loaded region pack \(pack.id, privacy: .public) v\(pack.version) cells=\(pack.cells.count)"
            )
            return pack
        } catch {
            AppLogger.speedLimit.error(
                "Failed loading \(resource).json: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private static func resourceURL(named resource: String, extension ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: resource, withExtension: ext) {
            return url
        }
        for bundle in Bundle.allBundles {
            if let url = bundle.url(forResource: resource, withExtension: ext) {
                return url
            }
        }
        return nil
    }

    static func decode(_ data: Data) throws -> SpeedLimitRegionPack {
        let dto = try JSONDecoder().decode(DTO.self, from: data)
        return SpeedLimitRegionPack(
            id: dto.id,
            name: dto.name,
            version: dto.version,
            gridScale: dto.gridScale,
            south: dto.bbox.south,
            west: dto.bbox.west,
            north: dto.bbox.north,
            east: dto.bbox.east,
            cells: dto.cells.filter { $0.value >= 5 && $0.value <= 200 }
        )
    }

    static func limit(for location: CLLocation, packs: [SpeedLimitRegionPack] = bundled) -> (pack: SpeedLimitRegionPack, kmh: Int)? {
        for pack in packs where pack.contains(location) {
            if let kmh = pack.limit(for: location) {
                return (pack, kmh)
            }
        }
        return nil
    }

    /// True when the rider is inside any bundled city pack (even if a cell has no maxspeed).
    static func isInsideBundledRegion(_ location: CLLocation, packs: [SpeedLimitRegionPack] = bundled) -> Bool {
        packs.contains { $0.contains(location) }
    }

    private struct DTO: Decodable {
        let id: String
        let name: String
        let version: Int
        let gridScale: Double
        let bbox: BBox
        let cells: [String: Int]

        struct BBox: Decodable {
            let south: Double
            let west: Double
            let north: Double
            let east: Double
        }
    }
}
