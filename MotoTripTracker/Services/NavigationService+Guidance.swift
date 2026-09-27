import CoreLocation
import Foundation
import MapKit
import UIKit
import os

extension NavigationService {
    func applyPreviewRoutes(_ mkRoutes: [MKRoute]) {
        isRouting = false
        isRecalculating = false
        guard !mkRoutes.isEmpty else {
            previewRoutes = []
            selectedRouteID = nil
            routeCoordinates = []
            previewErrorMessage = "Couldn't find a driving route."
            return
        }
        previewErrorMessage = nil
        previewRoutes = mkRoutes.map { route in
            let estimate = MotoTravelEstimator.estimate(
                distanceMeters: route.distance,
                carTravelTime: route.expectedTravelTime
            )
            return NavRouteOption(
                id: UUID(),
                coordinates: route.polyline.coordinates,
                distanceMeters: route.distance,
                expectedTravelTime: estimate.carTravelTime,
                motoTravelTime: estimate.motoTravelTime,
                trafficDelay: estimate.trafficDelay,
                steps: Self.navSteps(from: route)
            )
        }
        let first = previewRoutes[0]
        selectedRouteID = first.id
        applyPreviewSelection(first)
    }

    func applyPreviewSelection(_ option: NavRouteOption) {
        routeCoordinates = option.coordinates
        totalRouteDistance = option.distanceMeters
        totalTravelTime = option.motoTravelTime
        plannedCarTravelTime = option.expectedTravelTime
        plannedMotoTravelTime = option.motoTravelTime
        distanceRemaining = option.distanceMeters
        eta = option.motoTravelTime > 0
            ? Date().addingTimeInterval(option.motoTravelTime)
            : nil
        steps = []
        currentStepIndex = 0
        distanceToNextManeuver = 0
    }

    func applyRoute(
        coordinates: [CLLocationCoordinate2D],
        distance: CLLocationDistance,
        carTravelTime: TimeInterval,
        motoTravelTime: TimeInterval,
        steps: [NavStep],
        isRecalculation: Bool
    ) {
        routeCoordinates = coordinates
        totalRouteDistance = distance
        totalTravelTime = motoTravelTime
        plannedCarTravelTime = carTravelTime
        plannedMotoTravelTime = motoTravelTime
        distanceRemaining = distance
        eta = motoTravelTime > 0 ? Date().addingTimeInterval(motoTravelTime) : nil
        self.steps = steps
        currentStepIndex = 0
        distanceToNextManeuver = steps.first?.distance ?? distance
        approachedStepID = nil
        announcedStepID = nil
        matchedRouteIndex = 0
        matchedRouteBearing = 0
        matchedAlongRoute = 0
        offRouteGate.reset()
        isRouting = false
        isRecalculating = false
        isOffRoute = false
        nearestRouteDistance = 0
        if isRecalculation {
            lastRecalculateAt = Date()
        }
        AppLogger.navigation.notice(
            "Route \(isRecalculation ? "recalculated" : "computed"): \(Int(distance))m, \(steps.count) steps, car=\(Int(carTravelTime))s moto=\(Int(motoTravelTime))s"
        )
        onRouteApplied?(coordinates, motoTravelTime)
    }

    func recomputeRemaining(
        from coordinate: CLLocationCoordinate2D,
        course: CLLocationDirection = -1,
        speed: CLLocationSpeed = -1
    ) {
        let progress = NavigationRouteMath.progress(
            at: coordinate,
            on: routeCoordinates,
            nearIndex: matchedRouteIndex,
            course: course,
            speedMps: speed
        )
        matchedRouteIndex = progress.nearestIndex
        matchedRouteBearing = progress.routeBearing
        matchedAlongRoute = progress.alongRoute
        nearestRouteDistance = progress.nearestDistance
        distanceRemaining = progress.remaining
        if totalRouteDistance > 0, totalTravelTime > 0 {
            let fraction = min(max(progress.remaining / totalRouteDistance, 0), 1)
            eta = Date().addingTimeInterval(totalTravelTime * fraction)
        }
    }

    func advanceStepIfNeeded(from coordinate: CLLocationCoordinate2D) {
        guard let step = currentStep else {
            distanceToNextManeuver = distanceRemaining
            return
        }

        let toEnd = distanceAlongRoute(to: step, fallbackFrom: coordinate)
        distanceToNextManeuver = toEnd
        maybeAnnounceApproach(for: step, distanceMeters: toEnd)

        var index = currentStepIndex
        while index < steps.count - 1 {
            let along = distanceAlongRoute(to: steps[index], fallbackFrom: coordinate)
            if along <= Self.stepAdvanceMeters {
                index += 1
                continue
            }
            break
        }

        if index != currentStepIndex {
            currentStepIndex = index
            approachedStepID = nil
            if let next = currentStep {
                distanceToNextManeuver = distanceAlongRoute(to: next, fallbackFrom: coordinate)
                AppLogger.navigation.info("Advanced to step \(index + 1)/\(self.steps.count): \(next.instruction, privacy: .public)")
                announceStep(next)
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    /// Metres still to ride along the polyline to this maneuver, not the straight-line shortcut.
    private func distanceAlongRoute(to step: NavStep, fallbackFrom coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        if let stepAlong = NavigationRouteMath.alongRoute(
            of: step.endCoordinate,
            on: routeCoordinates,
            notBefore: matchedRouteIndex
        ) {
            return max(0, stepAlong - matchedAlongRoute)
        }
        return NavigationRouteMath.meters(from: coordinate, to: step.endCoordinate)
    }

    func maybeAnnounceApproach(for step: NavStep, distanceMeters: CLLocationDistance) {
        guard distanceMeters <= Self.approachAnnounceMeters else { return }
        guard approachedStepID != step.id else { return }
        approachedStepID = step.id
        let distance = Self.formatDistance(distanceMeters)
        voice.speak("In \(distance), \(step.instruction)")
    }

    func announceStep(_ step: NavStep) {
        guard announcedStepID != step.id else { return }
        announcedStepID = step.id
        voice.speak(step.instruction)
    }

    func checkOffRouteAndRecalculate(
        from coordinate: CLLocationCoordinate2D,
        horizontalAccuracy: CLLocationAccuracy,
        course: CLLocationDirection,
        speed: CLLocationSpeed,
        timestamp: Date
    ) {
        guard hasDestination, hasRoute, !isRouting, !isRecalculating else { return }

        let sample = CLLocation(
            coordinate: coordinate,
            altitude: 0,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: -1,
            course: course,
            speed: speed,
            timestamp: timestamp
        )
        let commit = offRouteGate.shouldRecalculate(
            crossTrack: nearestRouteDistance,
            horizontalAccuracy: horizontalAccuracy,
            course: course,
            routeBearing: matchedRouteBearing,
            speedMps: speed,
            location: sample
        )
        if commit {
            isOffRoute = true
            let now = Date()
            guard now.timeIntervalSince(lastRecalculateAt) >= Self.recalculateCooldown else { return }
            lastRecalculateAt = now
            AppLogger.navigation.notice(
                "Off route (\(Int(self.nearestRouteDistance))m) — recalculating"
            )
            computeRoute(isRecalculation: true)
        } else if !offRouteGate.isDiverging {
            isOffRoute = false
        }
    }

    static func navSteps(from route: MKRoute) -> [NavStep] {
        route.steps.compactMap { step in
            let instruction = step.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty else { return nil }
            let stepCoords = step.polyline.coordinates
            let end = stepCoords.last ?? step.polyline.coordinate
            return NavStep(instruction: instruction, distance: step.distance, endCoordinate: end)
        }
    }
}
