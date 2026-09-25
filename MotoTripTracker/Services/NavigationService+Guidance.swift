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

    func recomputeRemaining(from coordinate: CLLocationCoordinate2D) {
        let progress = NavigationRouteMath.progress(at: coordinate, on: routeCoordinates)
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

        let toEnd = NavigationRouteMath.meters(from: coordinate, to: step.endCoordinate)
        distanceToNextManeuver = toEnd
        maybeAnnounceApproach(for: step, distanceMeters: toEnd)

        let index = NavigationRouteMath.nextStepIndex(
            from: coordinate,
            steps: steps,
            currentIndex: currentStepIndex,
            advanceMeters: Self.stepAdvanceMeters
        )

        if index != currentStepIndex {
            currentStepIndex = index
            approachedStepID = nil
            if let next = currentStep {
                distanceToNextManeuver = NavigationRouteMath.meters(from: coordinate, to: next.endCoordinate)
                AppLogger.navigation.info("Advanced to step \(index + 1)/\(self.steps.count): \(next.instruction, privacy: .public)")
                announceStep(next)
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
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

    func checkOffRouteAndRecalculate(from coordinate: CLLocationCoordinate2D) {
        guard hasDestination, hasRoute, !isRouting, !isRecalculating else { return }

        if nearestRouteDistance > Self.offRouteThresholdMeters {
            isOffRoute = true
            let now = Date()
            guard now.timeIntervalSince(lastRecalculateAt) >= Self.recalculateCooldown else { return }
            lastRecalculateAt = now
            AppLogger.navigation.notice(
                "Off route (\(Int(self.nearestRouteDistance))m) — recalculating"
            )
            computeRoute(isRecalculation: true)
        } else if isOffRoute, nearestRouteDistance <= Self.offRouteThresholdMeters / 2 {
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
