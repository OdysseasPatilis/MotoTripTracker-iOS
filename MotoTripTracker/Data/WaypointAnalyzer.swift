import CoreLocation
import Foundation

enum WaypointAnalyzer {
    private static let stopSpeedThreshold = 0.5

    @MainActor
    static func analyzeAndMarkWaypoints(
        points: [RoutePoint],
        totalDistanceMeters: Double
    ) async {
        guard !points.isEmpty else { return }

        let startPoint = points[0]
        startPoint.isWaypoint = true
        startPoint.waypointType = "START"
        startPoint.waypointTitle = "Departure"
        startPoint.waypointSubtitle = await streetName(
            latitude: startPoint.latitude,
            longitude: startPoint.longitude
        )

        if let topSpeedPoint = points.max(by: { $0.speedMps < $1.speedMps }),
           topSpeedPoint.speedMps * 3.6 > 100 {
            topSpeedPoint.isWaypoint = true
            topSpeedPoint.waypointType = "TOP_SPEED"
            topSpeedPoint.waypointTitle = "Top Speed Hit"
            topSpeedPoint.waypointSubtitle = String(format: "%.1f km/h", topSpeedPoint.speedMps * 3.6)
        }

        let startAltitude = startPoint.altitude
        if let summitPoint = points.max(by: { $0.altitude < $1.altitude }),
           summitPoint.altitude > startAltitude + 100 {
            summitPoint.isWaypoint = true
            summitPoint.waypointType = "SUMMIT"
            summitPoint.waypointTitle = "Highest Elevation"
            summitPoint.waypointSubtitle = "\(Int(summitPoint.altitude))m above sea level"
        }

        var stopStart: RoutePoint?
        var distanceAtStopStart = 0.0

        if points.count > 2 {
            for i in 1..<(points.count - 1) {
                let point = points[i]
                if point.speedMps < stopSpeedThreshold {
                    if stopStart == nil {
                        stopStart = point
                        distanceAtStopStart = totalDistanceMeters * (Double(i) / Double(points.count))
                    }
                } else if let stop = stopStart {
                    let stopDurationMs = Int64((point.timestamp - stop.timestamp) * 1000)
                    if stopDurationMs > 2000 {
                        let kmString = String(format: "%.1f", distanceAtStopStart / 1000)
                        let minutes = (stopDurationMs / 1000) / 60
                        let seconds = (stopDurationMs / 1000) % 60
                        let timeStr = String(format: "%02d:%02d", minutes, seconds)

                        stop.isWaypoint = true
                        switch stopDurationMs {
                        case ..<10_000:
                            stop.waypointType = "STOP_SIGN"
                            stop.waypointTitle = "Stop Sign / Yield"
                            stop.waypointSubtitle = "\(kmString)km - \(timeStr) pause"
                        case ..<60_000:
                            stop.waypointType = "TRAFFIC_LIGHT"
                            stop.waypointTitle = "Traffic Light"
                            stop.waypointSubtitle = "\(kmString)km - \(timeStr) pause"
                        case ..<300_000:
                            stop.waypointType = "BRIEF_STOP"
                            stop.waypointTitle = "Brief Stop"
                            stop.waypointSubtitle = "\(kmString)km - \(timeStr) pause"
                        default:
                            stop.waypointType = "REST_STOP"
                            stop.waypointTitle = "Rest Stop"
                            let address = await streetName(
                                latitude: stop.latitude,
                                longitude: stop.longitude
                            )
                            stop.waypointSubtitle = "\(address) - \(timeStr) pause"
                        }
                    }
                    stopStart = nil
                }
            }
        }

        let endPoint = points[points.count - 1]
        endPoint.isWaypoint = true
        endPoint.waypointType = "END"
        endPoint.waypointTitle = "Arrival"
        endPoint.waypointSubtitle = await streetName(
            latitude: endPoint.latitude,
            longitude: endPoint.longitude
        )
    }

    private static func streetName(latitude: Double, longitude: Double) async -> String {
        let fallback = String(format: "%.4f° N, %.4f° E", latitude, longitude)
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            if let placemark = placemarks.first {
                return placemark.thoroughfare
                    ?? placemark.subLocality
                    ?? placemark.locality
                    ?? fallback
            }
        } catch {
            // Fall through to coordinates.
        }
        return fallback
    }
}
