import CoreLocation
import Foundation
import MapKit
import os

nonisolated struct WaypointSample: Sendable {
    let id: UUID
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let speedMps: Double
    let timestamp: TimeInterval
}

nonisolated struct WaypointMark: Sendable {
    let pointID: UUID
    let type: String
    let title: String
    var subtitle: String
}

nonisolated enum WaypointAnalyzer {
    private static let stopSpeedThreshold = 0.5

    static func analyze(
        points: [WaypointSample],
        totalDistanceMeters: Double,
        geocodeAddresses: Bool = true
    ) async -> [WaypointMark] {
        guard !points.isEmpty else {
            AppLogger.waypoint.debug("Waypoint analysis skipped — no points")
            return []
        }

        AppLogger.waypoint.info("Analyzing waypoints for \(points.count) route points")

        var marksByID: [UUID: WaypointMark] = [:]

        func mark(
            _ point: WaypointSample,
            type: String,
            title: String,
            subtitle: String
        ) {
            marksByID[point.id] = WaypointMark(
                pointID: point.id,
                type: type,
                title: title,
                subtitle: subtitle
            )
        }

        let startPoint = points[0]
        mark(
            startPoint,
            type: "START",
            title: "Departure",
            subtitle: coordinateLabel(latitude: startPoint.latitude, longitude: startPoint.longitude)
        )

        if let topSpeedPoint = points.max(by: { $0.speedMps < $1.speedMps }),
           topSpeedPoint.speedMps * 3.6 >= 100 {
            mark(
                topSpeedPoint,
                type: "TOP_SPEED",
                title: "Top Speed Hit",
                subtitle: String(format: "%.1f km/h", topSpeedPoint.speedMps * 3.6)
            )
        }

        let startAltitude = startPoint.altitude
        if let summitPoint = points.max(by: { $0.altitude < $1.altitude }),
           summitPoint.altitude > startAltitude + 100 {
            mark(
                summitPoint,
                type: "SUMMIT",
                title: "Highest Elevation",
                subtitle: "\(Int(summitPoint.altitude))m above sea level"
            )
        }

        var stopStart: WaypointSample?
        var distanceAtStopStart = 0.0
        var restStopIDs: [UUID] = []

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

                        let type: String
                        let title: String
                        switch stopDurationMs {
                        case ..<10_000:
                            type = "STOP_SIGN"
                            title = "Stop Sign / Yield"
                        case ..<60_000:
                            type = "TRAFFIC_LIGHT"
                            title = "Traffic Light"
                        case ..<300_000:
                            type = "BRIEF_STOP"
                            title = "Brief Stop"
                        default:
                            type = "REST_STOP"
                            title = "Rest Stop"
                            restStopIDs.append(stop.id)
                        }
                        mark(
                            stop,
                            type: type,
                            title: title,
                            subtitle: "\(kmString)km - \(timeStr) pause"
                        )
                    }
                    stopStart = nil
                }
            }
        }

        let endPoint = points[points.count - 1]
        mark(
            endPoint,
            type: "END",
            title: "Arrival",
            subtitle: coordinateLabel(latitude: endPoint.latitude, longitude: endPoint.longitude)
        )

        // Geocode only a few labels — reverse geocoding every stop on a long ride
        // used to block finalize for minutes (or never finish in background).
        if geocodeAddresses {
            if var startMark = marksByID[startPoint.id] {
                startMark.subtitle = await streetName(
                    latitude: startPoint.latitude,
                    longitude: startPoint.longitude
                )
                marksByID[startPoint.id] = startMark
            }
            if var endMark = marksByID[endPoint.id] {
                endMark.subtitle = await streetName(
                    latitude: endPoint.latitude,
                    longitude: endPoint.longitude
                )
                marksByID[endPoint.id] = endMark
            }
            for stopID in restStopIDs.prefix(3) {
                guard var stopMark = marksByID[stopID],
                      let stop = points.first(where: { $0.id == stopID }) else { continue }
                let address = await streetName(latitude: stop.latitude, longitude: stop.longitude)
                stopMark.subtitle = stopMark.subtitle.isEmpty
                    ? address
                    : "\(address) · \(stopMark.subtitle)"
                marksByID[stopID] = stopMark
            }
        }

        AppLogger.waypoint.notice(
            "Waypoint analysis complete — \(marksByID.count) markers on \(points.count) points"
        )
        return Array(marksByID.values)
    }

    private static func coordinateLabel(latitude: Double, longitude: Double) -> String {
        String(format: "%.4f° N, %.4f° E", latitude, longitude)
    }

    private static func streetName(latitude: Double, longitude: Double) async -> String {
        let fallback = coordinateLabel(latitude: latitude, longitude: longitude)
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else {
            return fallback
        }
        do {
            let mapItems = try await request.mapItems
            if let mapItem = mapItems.first {
                let name = mapItem.name
                    ?? mapItem.address?.shortAddress
                    ?? mapItem.addressRepresentations?.cityWithContext
                    ?? mapItem.addressRepresentations?.cityName
                    ?? fallback
                AppLogger.waypoint.debug(
                    "Geocoded @ \(AppLogger.coordinate(latitude, longitude), privacy: .public) → \(name, privacy: .public)"
                )
                return name
            }
        } catch {
            AppLogger.waypoint.debug(
                "Geocoder failed @ \(AppLogger.coordinate(latitude, longitude), privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
        return fallback
    }
}
