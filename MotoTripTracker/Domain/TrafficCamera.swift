import CoreLocation
import Foundation

enum TrafficCameraKind: String, Codable, Sendable, Hashable {
    case speed
    case redLight
}

enum TrafficCameraPackDownloadStatus: Equatable, Sendable {
    case idle
    case downloading(countryCode: String, countryName: String?)
    case failed(message: String)
}

struct TrafficCamera: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let latitude: Double
    let longitude: Double
    let kind: TrafficCameraKind

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }

    var speakText: String {
        switch kind {
        case .speed: return "Speed camera ahead"
        case .redLight: return "Red light camera ahead"
        }
    }

    func bannerText(distanceMeters: CLLocationDistance) -> String {
        let distance = NavigationService.formatDistance(distanceMeters)
        switch kind {
        case .speed: return "Speed camera · \(distance)"
        case .redLight: return "Red light camera · \(distance)"
        }
    }
}

struct TrafficCameraAlert: Equatable, Sendable {
    let camera: TrafficCamera
    let distanceMeters: CLLocationDistance

    var bannerText: String {
        camera.bannerText(distanceMeters: distanceMeters)
    }
}

/// Pure helpers for warn distance, heading filter, and OSM tag mapping.
nonisolated enum TrafficCameraLogic {
    static let minWarnMeters: CLLocationDistance = 250
    static let maxWarnMeters: CLLocationDistance = 700
    static let warnLeadTime: TimeInterval = 8
    static let slowSpeedMps: CLLocationSpeed = 3
    static let aheadHeadingToleranceDegrees: Double = 45

    static func warnDistanceMeters(speedMps: CLLocationSpeed) -> CLLocationDistance {
        guard speedMps.isFinite, speedMps > 0 else { return minWarnMeters }
        let raw = speedMps * warnLeadTime
        return min(max(raw, minWarnMeters), maxWarnMeters)
    }

    /// Absolute smallest angle between two bearings in degrees [0, 180].
    static func headingDeltaDegrees(_ a: Double, _ b: Double) -> Double {
        var delta = abs(a - b).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta = 360 - delta }
        return delta
    }

    static func isAhead(
        riderHeadingDegrees: CLLocationDirection,
        bearingToCameraDegrees: Double,
        speedMps: CLLocationSpeed
    ) -> Bool {
        if !speedMps.isFinite || speedMps < slowSpeedMps {
            return true
        }
        guard riderHeadingDegrees.isFinite, riderHeadingDegrees >= 0 else {
            return true
        }
        return headingDeltaDegrees(riderHeadingDegrees, bearingToCameraDegrees) <= aheadHeadingToleranceDegrees
    }

    static func bearingDegrees(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D
    ) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let bearing = atan2(y, x) * 180 / .pi
        return (bearing + 360).truncatingRemainder(dividingBy: 360)
    }

    static func kind(fromOSMTags tags: [String: String]) -> TrafficCameraKind? {
        // Prefer explicit red-light signals when multiple tags are present.
        switch tags["camera:type"]?.lowercased() {
        case "red_light", "traffic_signals", "signal":
            return .redLight
        case "speed", "speed_camera", "alpr", "plate":
            return .speed
        default:
            break
        }

        switch tags["enforcement"]?.lowercased() {
        case "traffic_signals":
            return .redLight
        case "maxspeed", "speed", "speeding":
            return .speed
        default:
            break
        }

        if tags["highway"] == "speed_camera" { return .speed }
        if tags["device"]?.lowercased() == "speed_camera" { return .speed }
        // Relation centers from type=enforcement queries.
        if tags["type"] == "enforcement" {
            switch tags["enforcement"]?.lowercased() {
            case "traffic_signals": return .redLight
            case "maxspeed", "speed", "speeding": return .speed
            default: break
            }
        }
        return nil
    }
}
