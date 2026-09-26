import CoreLocation
import Foundation

enum NavigationRouteMath {
    struct Progress: Equatable {
        var remaining: CLLocationDistance
        var nearestDistance: CLLocationDistance
        var nearestIndex: Int
    }

    /// How far behind the last match we still search, so a small rewind stays on the route.
    private static let matchBackMeters: CLLocationDistance = 250
    /// How far ahead we search. Farther vertices (a loop passing nearby) cannot steal the match.
    private static let matchForwardMeters: CLLocationDistance = 2_500

    static func progress(
        at coordinate: CLLocationCoordinate2D,
        on route: [CLLocationCoordinate2D],
        nearIndex: Int? = nil
    ) -> Progress {
        guard route.count > 1 else {
            return Progress(remaining: 0, nearestDistance: 0, nearestIndex: 0)
        }
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let indices = matchIndices(on: route, near: nearIndex)

        var nearestIndex = indices.lowerBound
        var nearestDistance = Double.greatestFiniteMagnitude
        for index in indices {
            let coord = route[index]
            let distance = here.distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
            if distance < nearestDistance {
                nearestDistance = distance
                nearestIndex = index
            }
        }

        var remaining = nearestDistance
        if nearestIndex < route.count - 1 {
            for index in nearestIndex..<(route.count - 1) {
                let a = route[index]
                let b = route[index + 1]
                remaining += CLLocation(latitude: a.latitude, longitude: a.longitude)
                    .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            }
        }
        return Progress(remaining: remaining, nearestDistance: nearestDistance, nearestIndex: nearestIndex)
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
