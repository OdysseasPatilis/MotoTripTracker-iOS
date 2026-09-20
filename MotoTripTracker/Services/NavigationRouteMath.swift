import CoreLocation
import Foundation

enum NavigationRouteMath {
    struct Progress: Equatable {
        var remaining: CLLocationDistance
        var nearestDistance: CLLocationDistance
        var nearestIndex: Int
    }

    static func progress(
        at coordinate: CLLocationCoordinate2D,
        on route: [CLLocationCoordinate2D]
    ) -> Progress {
        guard route.count > 1 else {
            return Progress(remaining: 0, nearestDistance: 0, nearestIndex: 0)
        }
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        var nearestIndex = 0
        var nearestDistance = Double.greatestFiniteMagnitude
        for (index, coord) in route.enumerated() {
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
