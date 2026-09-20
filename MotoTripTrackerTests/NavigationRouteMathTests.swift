import CoreLocation
import Foundation
import Testing
@testable import MotoTripTracker

struct NavigationRouteMathTests {
    private let start = CLLocationCoordinate2D(latitude: 37.98000, longitude: 23.72000)
    private let mid = CLLocationCoordinate2D(latitude: 37.98100, longitude: 23.72000)
    private let end = CLLocationCoordinate2D(latitude: 37.98200, longitude: 23.72000)

    @Test func remainingDistanceIsFullLengthAtStart() {
        let route = [start, end]
        let progress = NavigationRouteMath.progress(at: start, on: route)
        let full = distance(from: start, to: end)
        #expect(progress.nearestDistance < 1)
        #expect(abs(progress.remaining - full) < 1)
    }

    @Test func remainingDistanceIsNearZeroAtEnd() {
        let route = [start, end]
        let progress = NavigationRouteMath.progress(at: end, on: route)
        #expect(progress.nearestDistance < 1)
        #expect(progress.remaining < 1)
    }

    @Test func staysOnStepWhenFarFromManeuver() {
        let steps = [
            NavStep(instruction: "Turn right", distance: 100, endCoordinate: mid),
            NavStep(instruction: "Arrive", distance: 100, endCoordinate: end)
        ]
        let index = NavigationRouteMath.nextStepIndex(
            from: start,
            steps: steps,
            currentIndex: 0,
            advanceMeters: 35
        )
        #expect(index == 0)
    }

    @Test func advancesWhenWithinAdvanceMetersOfStepEnd() {
        let steps = [
            NavStep(instruction: "Turn right", distance: 100, endCoordinate: start),
            NavStep(instruction: "Arrive", distance: 100, endCoordinate: end)
        ]
        let nearStart = CLLocationCoordinate2D(latitude: 37.98008, longitude: 23.72000)
        let index = NavigationRouteMath.nextStepIndex(
            from: nearStart,
            steps: steps,
            currentIndex: 0,
            advanceMeters: 35
        )
        #expect(index == 1)
    }

    @Test func doesNotAdvancePastLastStep() {
        let steps = [
            NavStep(instruction: "Arrive", distance: 50, endCoordinate: start)
        ]
        let index = NavigationRouteMath.nextStepIndex(
            from: start,
            steps: steps,
            currentIndex: 0,
            advanceMeters: 35
        )
        #expect(index == 0)
    }

    @Test func arrivalRequiresNearDestinationAndRouteEnd() {
        #expect(
            NavigationRouteMath.isArrivalCandidate(
                metersToDestination: 20,
                distanceRemaining: 40,
                currentStepIndex: 0,
                stepCount: 3,
                destinationThresholdMeters: 45,
                remainingMaxMeters: 120
            )
        )
        #expect(
            !NavigationRouteMath.isArrivalCandidate(
                metersToDestination: 80,
                distanceRemaining: 40,
                currentStepIndex: 0,
                stepCount: 3,
                destinationThresholdMeters: 45,
                remainingMaxMeters: 120
            )
        )
    }

    @Test func arrivalOnFinalStepEvenIfRemainingPolylineIsLong() {
        #expect(
            NavigationRouteMath.isArrivalCandidate(
                metersToDestination: 20,
                distanceRemaining: 400,
                currentStepIndex: 2,
                stepCount: 3,
                destinationThresholdMeters: 45,
                remainingMaxMeters: 120
            )
        )
    }

    @Test func formatDistanceUsesMetersThenKilometers() {
        #expect(NavigationRouteMath.formatDistance(42) == "42 m")
        #expect(NavigationRouteMath.formatDistance(1500) == "1.5 km")
    }

    private func distance(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
