import CoreLocation
import Foundation

enum NavigationRouteMath {
    struct Progress: Equatable {
        var remaining: CLLocationDistance
        var nearestDistance: CLLocationDistance
        var nearestIndex: Int
        /// Bearing of the matched route segment, degrees clockwise from north.
        var routeBearing: CLLocationDirection = 0
        /// Distance from the start of the route to the snapped point.
        var alongRoute: CLLocationDistance = 0
    }

    /// How far behind the last match we still search, so a small rewind stays on the route.
    private static let matchBackMeters: CLLocationDistance = 300
    /// How far ahead we search before falling back to the whole route.
    private static let matchForwardMeters: CLLocationDistance = 4_000
    /// Added to the score for every 90° the rider's course disagrees with the segment.
    private static let headingPenaltyPer90Degrees: CLLocationDistance = 50

    static func progress(
        at coordinate: CLLocationCoordinate2D,
        on route: [CLLocationCoordinate2D],
        nearIndex: Int? = nil,
        course: CLLocationDirection = -1,
        speedMps: CLLocationSpeed = -1
    ) -> Progress {
        guard route.count > 1 else {
            return Progress(remaining: 0, nearestDistance: 0, nearestIndex: 0)
        }
        let prefix = prefixMeters(on: route)
        let total = prefix.last ?? 0
        let anchor = nearIndex.flatMap { route.indices.contains($0) ? $0 : nil }

        let localVertices = matchIndices(on: route, near: anchor)
        guard let local = bestMatch(
            of: coordinate,
            on: route,
            vertices: localVertices,
            prefix: prefix,
            anchor: anchor ?? 0,
            course: course,
            speedMps: speedMps
        ) else {
            return Progress(remaining: total, nearestDistance: 0, nearestIndex: 0, alongRoute: 0)
        }

        let chosen: SegmentMatch
        if anchor != nil, local.crossTrack > 80 {
            let global = bestMatch(
                of: coordinate,
                on: route,
                vertices: route.indices,
                prefix: prefix,
                anchor: anchor ?? 0,
                course: course,
                speedMps: speedMps
            )
            if let global, global.crossTrack <= 35, global.crossTrack + 40 < local.crossTrack {
                chosen = global
            } else {
                chosen = local
            }
        } else {
            chosen = local
        }

        let snappedIndex = chosen.fraction > 0.85 ? min(chosen.segmentIndex + 1, route.count - 1) : chosen.segmentIndex
        return Progress(
            remaining: max(0, total - chosen.along),
            nearestDistance: chosen.crossTrack,
            nearestIndex: snappedIndex,
            routeBearing: chosen.bearing,
            alongRoute: chosen.along
        )
    }

    /// Distance from the route start to where `coordinate` sits on the polyline, searching ahead of `notBefore`.
    /// Returns nil when the point is not actually on the route.
    static func alongRoute(
        of coordinate: CLLocationCoordinate2D,
        on route: [CLLocationCoordinate2D],
        notBefore index: Int
    ) -> CLLocationDistance? {
        guard route.count > 1 else { return nil }
        let prefix = prefixMeters(on: route)
        let start = min(max(0, index), route.count - 2)
        var bestDistance = CLLocationDistance.greatestFiniteMagnitude
        var bestAlong: CLLocationDistance?
        for segment in start..<(route.count - 1) {
            let projected = project(coordinate, onto: route[segment], route[segment + 1])
            guard projected.distance + 0.5 < bestDistance else { continue }
            bestDistance = projected.distance
            let length = prefix[segment + 1] - prefix[segment]
            bestAlong = prefix[segment] + projected.fraction * length
        }
        guard bestDistance < 40 else { return nil }
        return bestAlong
    }

    static func angularDifference(_ a: CLLocationDirection, _ b: CLLocationDirection) -> CLLocationDirection {
        let raw = abs(a - b).truncatingRemainder(dividingBy: 360)
        return raw > 180 ? 360 - raw : raw
    }

    /// Vertices around the last match. A full-route search lets one sideways fix snap onto
    /// a different part of the polyline that happens to pass nearby.
    private static func matchIndices(on route: [CLLocationCoordinate2D], near nearIndex: Int?) -> Range<Int> {
        guard let nearIndex, route.indices.contains(nearIndex) else {
            return route.indices
        }

        var start = nearIndex
        var backward: CLLocationDistance = 0
        while start > 0, backward < matchBackMeters {
            backward += meters(from: route[start - 1], to: route[start])
            start -= 1
        }

        var end = nearIndex
        var forward: CLLocationDistance = 0
        while end < route.count - 1, forward < matchForwardMeters {
            forward += meters(from: route[end], to: route[end + 1])
            end += 1
        }
        return start..<(end + 1)
    }

    private struct SegmentMatch {
        var segmentIndex: Int
        var fraction: Double
        var crossTrack: CLLocationDistance
        var bearing: CLLocationDirection
        var along: CLLocationDistance
        var score: CLLocationDistance
    }

    private struct Projection {
        var distance: CLLocationDistance
        var fraction: Double
        var bearing: CLLocationDirection
    }

    private static func bestMatch(
        of coordinate: CLLocationCoordinate2D,
        on route: [CLLocationCoordinate2D],
        vertices: Range<Int>,
        prefix: [CLLocationDistance],
        anchor: Int,
        course: CLLocationDirection,
        speedMps: CLLocationSpeed
    ) -> SegmentMatch? {
        let lower = max(0, vertices.lowerBound)
        let upper = min(route.count, vertices.upperBound)
        guard upper - lower >= 2 else { return nil }
        let useHeading = course >= 0 && speedMps >= 3

        var best: SegmentMatch?
        for segment in lower..<(upper - 1) {
            let projected = project(coordinate, onto: route[segment], route[segment + 1])
            let penalty = useHeading
                ? (angularDifference(course, projected.bearing) / 90) * headingPenaltyPer90Degrees
                : 0
            let length = prefix[segment + 1] - prefix[segment]
            let along = prefix[segment] + projected.fraction * length
            let candidate = SegmentMatch(
                segmentIndex: segment,
                fraction: projected.fraction,
                crossTrack: projected.distance,
                bearing: projected.bearing,
                along: along,
                score: projected.distance + penalty
            )
            guard let current = best else {
                best = candidate
                continue
            }
            let closer = candidate.score + 1 < current.score
            let tiedButSteadier = abs(candidate.score - current.score) <= 1
                && abs(segment - anchor) < abs(current.segmentIndex - anchor)
            if closer || tiedButSteadier {
                best = candidate
            }
        }
        return best
    }

    private static func project(
        _ point: CLLocationCoordinate2D,
        onto start: CLLocationCoordinate2D,
        _ end: CLLocationCoordinate2D
    ) -> Projection {
        let latScale = 111_320.0
        let lonScale = 111_320.0 * cos(start.latitude * .pi / 180)
        let east = (end.longitude - start.longitude) * lonScale
        let north = (end.latitude - start.latitude) * latScale
        let pointEast = (point.longitude - start.longitude) * lonScale
        let pointNorth = (point.latitude - start.latitude) * latScale
        let lengthSquared = east * east + north * north
        let fraction: Double
        if lengthSquared < 0.01 {
            fraction = 0
        } else {
            let raw = (pointEast * east + pointNorth * north) / lengthSquared
            fraction = min(1, max(0, raw))
        }
        let footEast = east * fraction
        let footNorth = north * fraction
        var bearing = atan2(east, north) * 180 / .pi
        if bearing < 0 { bearing += 360 }
        return Projection(
            distance: hypot(pointEast - footEast, pointNorth - footNorth),
            fraction: fraction,
            bearing: bearing
        )
    }

    private static func prefixMeters(on route: [CLLocationCoordinate2D]) -> [CLLocationDistance] {
        var prefix = [CLLocationDistance]()
        prefix.reserveCapacity(route.count)
        var running: CLLocationDistance = 0
        prefix.append(0)
        for index in 0..<(route.count - 1) {
            running += meters(from: route[index], to: route[index + 1])
            prefix.append(running)
        }
        return prefix
    }

    static func nextStepIndex(
        from coordinate: CLLocationCoordinate2D,
        steps: [NavStep],
        currentIndex: Int,
        advanceMeters: CLLocationDistance
    ) -> Int {
        guard !steps.isEmpty, steps.indices.contains(currentIndex) else {
            return currentIndex
        }
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var index = currentIndex
        while index < steps.count {
            let candidate = steps[index]
            let distance = here.distance(
                from: CLLocation(
                    latitude: candidate.endCoordinate.latitude,
                    longitude: candidate.endCoordinate.longitude
                )
            )
            if distance <= advanceMeters, index < steps.count - 1 {
                index += 1
                continue
            }
            break
        }
        return index
    }

    static func isArrivalCandidate(
        metersToDestination: CLLocationDistance,
        distanceRemaining: CLLocationDistance,
        currentStepIndex: Int,
        stepCount: Int,
        destinationThresholdMeters: CLLocationDistance,
        remainingMaxMeters: CLLocationDistance
    ) -> Bool {
        let nearDestination = metersToDestination <= destinationThresholdMeters
        let nearRouteEnd = distanceRemaining <= remainingMaxMeters
        let onFinalStep = stepCount > 0 && currentStepIndex >= stepCount - 1
        return nearDestination && (nearRouteEnd || onFinalStep)
    }

    static func formatDistance(_ meters: CLLocationDistance) -> String {
        if meters >= 1000 {
            return String(format: "%.1f km", meters / 1000)
        }
        return "\(max(0, Int(meters.rounded()))) m"
    }

    static func meters(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
