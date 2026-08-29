import CoreLocation
import Foundation

/// Interpolated replay frame from recorded route points.
struct RouteReplayFrame: Sendable {
    let coordinate: CLLocationCoordinate2D
    let speedKmh: Double
    let altitude: Double
    let elapsed: TimeInterval
    /// Index of the segment start in the source points array.
    let segmentIndex: Int
}

/// Time-based route replay from persisted `RoutePoint`s.
struct RouteReplayEngine: Sendable {
    let points: [RoutePoint]

    var isValid: Bool { points.count >= 2 }

    var duration: TimeInterval {
        guard let first = points.first?.timestamp, let last = points.last?.timestamp else { return 0 }
        return max(0, last - first)
    }

    func frame(at elapsed: TimeInterval) -> RouteReplayFrame? {
        guard points.count >= 2, let firstTs = points.first?.timestamp else { return nil }
        let clamped = max(0, min(elapsed, duration))
        let targetTs = firstTs + clamped

        if targetTs <= points[0].timestamp {
            let p = points[0]
            return RouteReplayFrame(
                coordinate: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude),
                speedKmh: p.speedMps * 3.6,
                altitude: p.altitude,
                elapsed: clamped,
                segmentIndex: 0
            )
        }

        for index in 0..<(points.count - 1) {
            let a = points[index]
            let b = points[index + 1]
            if targetTs >= a.timestamp, targetTs <= b.timestamp {
                let span = b.timestamp - a.timestamp
                let t = span > 0 ? (targetTs - a.timestamp) / span : 0
                return RouteReplayFrame(
                    coordinate: CLLocationCoordinate2D(
                        latitude: a.latitude + (b.latitude - a.latitude) * t,
                        longitude: a.longitude + (b.longitude - a.longitude) * t
                    ),
                    speedKmh: (a.speedMps + (b.speedMps - a.speedMps) * t) * 3.6,
                    altitude: a.altitude + (b.altitude - a.altitude) * t,
                    elapsed: clamped,
                    segmentIndex: index
                )
            }
        }

        let last = points[points.count - 1]
        return RouteReplayFrame(
            coordinate: CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude),
            speedKmh: last.speedMps * 3.6,
            altitude: last.altitude,
            elapsed: clamped,
            segmentIndex: max(0, points.count - 2)
        )
    }

    /// Coordinates from start through the current replay position (inclusive).
    func trailCoordinates(upTo frame: RouteReplayFrame) -> [CLLocationCoordinate2D] {
        guard !points.isEmpty else { return [] }
        var coords = points.prefix(frame.segmentIndex + 1).map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        coords.append(frame.coordinate)
        return coords
    }
}
