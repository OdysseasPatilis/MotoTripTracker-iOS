import CoreLocation
import Foundation

/// Chooses stored GPS points, or reconstructs a path from the encoded polyline
/// when SwiftData faults an empty relationship after a long background ride.
struct RideRouteDisplay {
    let points: [RoutePoint]
    let usingPolylineFallback: Bool

    var coordinates: [CLLocationCoordinate2D] {
        points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var waypoints: [RoutePoint] {
        usingPolylineFallback ? [] : points.filter(\.isWaypoint)
    }

    static func resolve(trip: Trip?, storedPoints: [RoutePoint]) -> RideRouteDisplay {
        if storedPoints.count >= 2 {
            return RideRouteDisplay(points: storedPoints, usingPolylineFallback: false)
        }

        guard let encoded = trip?.encodedRoutePolyline, !encoded.isEmpty else {
            return RideRouteDisplay(points: storedPoints, usingPolylineFallback: false)
        }

        let decoded = PolylineEncoder.decode(encoded)
        guard decoded.count >= 2 else {
            return RideRouteDisplay(points: storedPoints, usingPolylineFallback: false)
        }

        let start = trip?.startTime ?? Date().timeIntervalSince1970
        let end = trip?.endTime ?? start + Double(max(decoded.count - 1, 1))
        let span = max(end - start, Double(decoded.count - 1))
        let rebuilt = decoded.enumerated().map { index, coord in
            let timestamp = decoded.count == 1
                ? start
                : start + span * Double(index) / Double(decoded.count - 1)
            return RoutePoint(
                latitude: coord.lat,
                longitude: coord.lng,
                altitude: 0,
                speedMps: 0,
                timestamp: timestamp
            )
        }
        return RideRouteDisplay(points: rebuilt, usingPolylineFallback: true)
    }
}
