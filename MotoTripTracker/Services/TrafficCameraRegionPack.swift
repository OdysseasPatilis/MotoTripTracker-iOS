import CoreLocation
import Foundation
import os

/// Bundled offline traffic-camera points for a geographic region (e.g. Greater Athens).
nonisolated struct TrafficCameraRegionPack: Sendable {
    let id: String
    let name: String
    let version: Int
    let south: Double
    let west: Double
    let north: Double
    let east: Double
    let cameras: [TrafficCamera]

    func contains(latitude: Double, longitude: Double) -> Bool {
        latitude >= south && latitude <= north && longitude >= west && longitude <= east
    }

    func contains(_ location: CLLocation) -> Bool {
        contains(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
    }
}

nonisolated enum TrafficCameraRegionPackStore {
    static let bundled: [TrafficCameraRegionPack] = {
        ["athens_traffic_cameras"].compactMap { loadBundled(named: $0) }
    }()

    static func loadBundled(named resource: String, bundle: Bundle? = nil) -> TrafficCameraRegionPack? {
        let url: URL?
        if let bundle {
            url = bundle.url(forResource: resource, withExtension: "json")
        } else {
            url = resourceURL(named: resource, extension: "json")
        }
        guard let url else {
            AppLogger.trafficCamera.error("Missing bundled traffic-camera pack \(resource).json")
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let pack = try decode(data)
            AppLogger.trafficCamera.info(
                "Loaded camera pack \(pack.id, privacy: .public) v\(pack.version) count=\(pack.cameras.count)"
            )
            return pack
        } catch {
            AppLogger.trafficCamera.error(
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

    static func decode(_ data: Data) throws -> TrafficCameraRegionPack {
        let dto = try JSONDecoder().decode(DTO.self, from: data)
        let cameras = dto.cameras.compactMap { entry -> TrafficCamera? in
            guard entry.lat.isFinite, entry.lon.isFinite,
                  abs(entry.lat) <= 90, abs(entry.lon) <= 180,
                  !entry.id.isEmpty
            else { return nil }
            return TrafficCamera(
                id: entry.id,
                latitude: entry.lat,
                longitude: entry.lon,
                kind: entry.kind
            )
        }
        return TrafficCameraRegionPack(
            id: dto.id,
            name: dto.name,
            version: dto.version,
            south: dto.bbox.south,
            west: dto.bbox.west,
            north: dto.bbox.north,
            east: dto.bbox.east,
            cameras: cameras
        )
    }

    static func isInsideBundledRegion(_ location: CLLocation, packs: [TrafficCameraRegionPack] = bundled) -> Bool {
        packs.contains { $0.contains(location) }
    }

    private struct DTO: Decodable {
        let id: String
        let name: String
        let version: Int
        let bbox: BBox
        let cameras: [CameraDTO]

        struct BBox: Decodable {
            let south: Double
            let west: Double
            let north: Double
            let east: Double
        }

        struct CameraDTO: Decodable {
            let id: String
            let lat: Double
            let lon: Double
            let kind: TrafficCameraKind
        }
    }
}
