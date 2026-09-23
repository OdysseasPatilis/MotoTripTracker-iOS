import CoreLocation
import Foundation
import Testing
@testable import MotoTripTracker

struct TrafficCameraLogicTests {

    @Test func trafficCameraWarnDistanceClampsBySpeed() {
        #expect(TrafficCameraLogic.warnDistanceMeters(speedMps: -1) == 250)
        #expect(TrafficCameraLogic.warnDistanceMeters(speedMps: 0) == 250)
        #expect(TrafficCameraLogic.warnDistanceMeters(speedMps: 40) == 320) // 40*8
        #expect(TrafficCameraLogic.warnDistanceMeters(speedMps: 100) == 700)
    }

    @Test func trafficCameraAheadFilterUsesHeading() {
        #expect(
            TrafficCameraLogic.isAhead(
                riderHeadingDegrees: 0,
                bearingToCameraDegrees: 10,
                speedMps: 15
            )
        )
        #expect(
            !TrafficCameraLogic.isAhead(
                riderHeadingDegrees: 0,
                bearingToCameraDegrees: 180,
                speedMps: 15
            )
        )
        // Slow / uncertain: treat as ahead so city crawl still warns.
        #expect(
            TrafficCameraLogic.isAhead(
                riderHeadingDegrees: 0,
                bearingToCameraDegrees: 180,
                speedMps: 2
            )
        )
    }

    @Test func trafficCameraKindFromOSMTags() {
        #expect(TrafficCameraLogic.kind(fromOSMTags: ["highway": "speed_camera"]) == .speed)
        #expect(TrafficCameraLogic.kind(fromOSMTags: ["device": "speed_camera"]) == .speed)
        #expect(TrafficCameraLogic.kind(fromOSMTags: ["enforcement": "maxspeed"]) == .speed)
        #expect(TrafficCameraLogic.kind(fromOSMTags: ["enforcement": "speed"]) == .speed)
        #expect(TrafficCameraLogic.kind(fromOSMTags: ["enforcement": "traffic_signals"]) == .redLight)
        #expect(TrafficCameraLogic.kind(fromOSMTags: ["camera:type": "red_light"]) == .redLight)
        #expect(TrafficCameraLogic.kind(fromOSMTags: ["camera:type": "speed"]) == .speed)
        #expect(TrafficCameraLogic.kind(fromOSMTags: ["highway": "traffic_signals"]) == nil)
    }

    @Test func trafficCameraPackDecodesPointList() throws {
        let json = """
        {
          "id": "athens_traffic_cameras",
          "name": "Greater Athens traffic cameras",
          "version": 1,
          "bbox": {"south": 37.82, "west": 23.55, "north": 38.15, "east": 23.95},
          "cameras": [
            {"id": "osm:node/1", "lat": 37.97, "lon": 23.72, "kind": "speed"},
            {"id": "osm:node/2", "lat": 37.98, "lon": 23.73, "kind": "redLight"}
          ]
        }
        """.data(using: .utf8)!
        let pack = try TrafficCameraRegionPackStore.decode(json)
        #expect(pack.id == "athens_traffic_cameras")
        #expect(pack.cameras.count == 2)
        #expect(pack.contains(latitude: 37.97, longitude: 23.72))
        #expect(!pack.contains(latitude: 40.0, longitude: 23.72))
        #expect(pack.cameras[0].kind == .speed)
        #expect(pack.cameras[1].kind == .redLight)
    }

    @Test func trafficCameraParsesOverpassElements() {
        let json = """
        {
          "elements": [
            {"type":"node","id":10,"lat":37.97,"lon":23.72,"tags":{"highway":"speed_camera"}},
            {"type":"way","id":20,"center":{"lat":37.98,"lon":23.73},"tags":{"enforcement":"traffic_signals"}},
            {"type":"node","id":25,"lat":37.975,"lon":23.725,"tags":{"device":"speed_camera"}},
            {"type":"node","id":26,"lat":37.976,"lon":23.726,"tags":{"camera:type":"red_light"}},
            {"type":"node","id":30,"lat":37.99,"lon":23.74,"tags":{"highway":"bus_stop"}}
          ]
        }
        """.data(using: .utf8)!
        let cameras = TrafficCameraService.parseOverpassCameras(from: json)
        #expect(cameras.count == 4)
        #expect(cameras[0].id == "osm:node/10")
        #expect(cameras[0].kind == .speed)
        #expect(cameras[1].id == "osm:way/20")
        #expect(cameras[1].kind == .redLight)
        #expect(cameras[2].kind == .speed)
        #expect(cameras[3].kind == .redLight)
    }

    @Test func trafficCameraParsesSpeedcamsCSV() throws {
        let csv = """
        # comment
        id,latitude,longitude,type,maxspeed,unit,country_code,region
        123,37.97,23.72,fixed,50,kmh,GR,
        456,38.0,23.8,fixed,,,GR,
        """
        let pack = try TrafficCameraPackDownloader.parseCSV(csv, countryCode: "GR")
        #expect(pack.cameras.count == 2)
        #expect(pack.cameras[0].id == "osm:node/123")
        #expect(pack.cameras[0].kind == .speed)
        #expect(pack.cameras[0].latitude == 37.97)
        #expect(pack.id == "country_GR")
        #expect(TrafficCameraPackDownloader.csvURL(countryCode: "IT").absoluteString
            == "https://speedcams.world/downloads/it/it-all.csv")
    }

    @Test func trafficCameraCSVSkipsBadRows() throws {
        let csv = """
        id,latitude,longitude,type,maxspeed,unit,country_code,region
        bad,x,y,fixed,,,GR,
        789,40.5,22.9,fixed,,,GR,
        """
        let pack = try TrafficCameraPackDownloader.parseCSV(csv, countryCode: "GR")
        #expect(pack.cameras.count == 1)
        #expect(pack.cameras[0].id == "osm:node/789")
    }

    @Test func trafficCameraPackStoreTTLAndUnsupported() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TrafficCameraPackStore(directory: dir)
        let pack = try TrafficCameraPackDownloader.parseCSV(
            """
            id,latitude,longitude,type,maxspeed,unit,country_code,region
            1,1,1,fixed,,,IT,
            """,
            countryCode: "IT"
        )
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        try store.save(pack: pack, countryCode: "IT", downloadedAt: t0)
        #expect(store.isFresh(countryCode: "IT", now: t0.addingTimeInterval(10), ttl: 30 * 24 * 3600))
        #expect(!store.isFresh(countryCode: "IT", now: t0.addingTimeInterval(31 * 24 * 3600), ttl: 30 * 24 * 3600))
        store.markUnsupported(countryCode: "XX", at: t0, cooldown: 24 * 3600)
        #expect(store.isUnsupported(countryCode: "XX", now: t0.addingTimeInterval(3600)))
        #expect(!store.isUnsupported(countryCode: "XX", now: t0.addingTimeInterval(25 * 3600)))
        #expect(store.loadPack(countryCode: "IT")?.pack.cameras.count == 1)
    }

    @Test func trafficCameraCountryResolverRefreshGate() {
        let a = CLLocation(latitude: 37.97, longitude: 23.72)
        let near = CLLocation(latitude: 37.971, longitude: 23.721)
        let far = CLLocation(latitude: 38.2, longitude: 23.9)
        let t0 = Date(timeIntervalSince1970: 0)
        #expect(
            !TrafficCameraCountryResolver.shouldRefresh(
                lastLocation: a,
                lastResolvedAt: t0,
                newLocation: near,
                now: t0.addingTimeInterval(60)
            )
        )
        #expect(
            TrafficCameraCountryResolver.shouldRefresh(
                lastLocation: a,
                lastResolvedAt: t0,
                newLocation: far,
                now: t0.addingTimeInterval(60)
            )
        )
        #expect(
            TrafficCameraCountryResolver.shouldRefresh(
                lastLocation: a,
                lastResolvedAt: t0,
                newLocation: near,
                now: t0.addingTimeInterval(601)
            )
        )
    }

    @Test func trafficCameraVisibleRegionFiltersAndLimits() {
        let cameras = [
            TrafficCamera(id: "a", latitude: 37.974, longitude: 23.734, kind: .speed),
            TrafficCamera(id: "b", latitude: 37.98, longitude: 23.74, kind: .redLight),
            TrafficCamera(id: "c", latitude: 40.0, longitude: 23.0, kind: .speed)
        ]
        let region = VisibleMapRegion(
            centerLatitude: 37.975,
            centerLongitude: 23.735,
            latitudeDelta: 0.05,
            longitudeDelta: 0.05
        )
        let visible = TrafficCameraLogic.cameras(from: cameras, in: region, limit: 10)
        #expect(Set(visible.map(\.id)) == Set(["a", "b"]))

        let limited = TrafficCameraLogic.cameras(from: cameras, in: region, limit: 1)
        #expect(limited.count == 1)
        #expect(limited[0].id == "a")
    }
}
