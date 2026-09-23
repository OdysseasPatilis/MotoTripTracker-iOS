import CoreLocation
import Foundation
import MapKit
import UIKit
import os

/// Driving routes and in-app turn-by-turn guidance.
/// Destination autocomplete lives in `DestinationSearchCompleter`.
@Observable
@MainActor
final class NavigationService {
    let destinationSearch = DestinationSearchCompleter()

    var searchQuery: String {
        get { destinationSearch.searchQuery }
        set { destinationSearch.searchQuery = newValue }
    }

    var searchResults: [MKLocalSearchCompletion] { destinationSearch.searchResults }

    private(set) var destinationCoordinate: CLLocationCoordinate2D?
    private(set) var destinationName: String?
    var routeCoordinates: [CLLocationCoordinate2D] = []
    var distanceRemaining: CLLocationDistance = 0
    var eta: Date?
    var isRouting = false
    var isOffRoute = false
    var isRecalculating = false
    private(set) var phase: NavigationPhase = .idle
    var previewRoutes: [NavRouteOption] = []
    var selectedRouteID: UUID?
    var previewErrorMessage: String?

    /// Last completed navigation timing (car vs moto vs actual), for a short HUD banner.
    private(set) var lastTimingResult: NavTimingResult?

    var steps: [NavStep] = []
    var currentStepIndex: Int = 0
    /// Distance from the rider to the end of the current maneuver.
    var distanceToNextManeuver: CLLocationDistance = 0

    /// Spoken turn prompts; persisted across launches (default on).
    var isVoiceEnabled: Bool = true {
        didSet {
            voice.isEnabled = isVoiceEnabled
            if !isVoiceEnabled { voice.stop() }
        }
    }

    let voice: NavigationVoicePrompt
    private(set) var origin: CLLocationCoordinate2D?
    var totalRouteDistance: CLLocationDistance = 0
    /// Active guidance uses moto-adjusted remaining time scaling.
    var totalTravelTime: TimeInterval = 0
    var plannedCarTravelTime: TimeInterval = 0
    var plannedMotoTravelTime: TimeInterval = 0
    private var navigationStartedAt: Date?
    var lastRecalculateAt: Date = .distantPast
    var nearestRouteDistance: CLLocationDistance = 0
    var approachedStepID: UUID?
    var announcedStepID: UUID?
    private var routeRequestGeneration: UInt64 = 0

    /// Called when a driving route is applied (initial or recalculated).
    var onRouteApplied: (([CLLocationCoordinate2D], TimeInterval) -> Void)?
    var onRouteCleared: (() -> Void)?

    /// How far from the planned polyline before we treat the rider as off-route.
    static let offRouteThresholdMeters: CLLocationDistance = 80
    /// Advance to the next step when within this distance of its end.
    static let stepAdvanceMeters: CLLocationDistance = 35
    /// Speak an approach prompt once when within this distance of the maneuver.
    static let approachAnnounceMeters: CLLocationDistance = 250
    static let recalculateCooldown: TimeInterval = 12
    /// Arrive when within this of the destination pin…
    private static let arrivalThresholdMeters: CLLocationDistance = 45
    /// …and remaining route distance is also small (avoids early finish if you pass the pin).
    private static let arrivalRemainingMaxMeters: CLLocationDistance = 120
    /// Require a short dwell so a single GPS bounce doesn't end guidance.
    private static let arrivalDwell: TimeInterval = 2.5

    private var arrivalCandidateSince: Date?

    init(voice: NavigationVoicePrompt? = nil) {
        self.voice = voice ?? NavigationVoicePrompt()
        isVoiceEnabled = self.voice.isEnabled
    }

    func toggleVoice() {
        isVoiceEnabled.toggle()
    }

    /// Starts MapKit's local-search daemon so the first destination sheet isn't cold.
    func warmUpSearchCompleter() {
        destinationSearch.warmUp()
    }

    var hasDestination: Bool { destinationCoordinate != nil }
    var hasRoute: Bool { routeCoordinates.count > 1 }
    var selectedPreviewRoute: NavRouteOption? {
        previewRoutes.first { $0.id == selectedRouteID } ?? previewRoutes.first
    }
    var isPreviewing: Bool { phase == .previewing }
    var isNavigating: Bool { phase == .navigating }

    /// 0 at departure, 1 when the planned route is complete.
    var routeProgressFraction: Double {
        guard totalRouteDistance > 0 else { return 0 }
        let traveled = max(0, totalRouteDistance - distanceRemaining)
        return min(1, traveled / totalRouteDistance)
    }

    var currentStep: NavStep? {
        guard steps.indices.contains(currentStepIndex) else { return nil }
        return steps[currentStepIndex]
    }

    var summaryText: String {
        let distanceString = Self.formatDistance(distanceRemaining)
        guard let eta else { return distanceString }
        return "\(distanceString) · Moto ETA \(eta.formatted(date: .omitted, time: .shortened))"
    }

    /// Extra chip line when car traffic is meaningfully worse than the moto estimate.
    var trafficHintText: String? {
        guard phase == .navigating || phase == .previewing else { return nil }
        let delay = plannedCarTravelTime - plannedMotoTravelTime
        guard delay >= 90 else { return nil }
        return "Cars +\(MotoTravelEstimator.formatMinutes(delay))"
    }

    /// Compact line for the Live Activity / HUD secondary line.
    var guidanceSummary: String {
        if isRecalculating { return "Recalculating…" }
        if isOffRoute { return "Off route — recalculating" }
        if let step = currentStep {
            return "\(Self.formatDistance(distanceToNextManeuver)) · \(step.instruction)"
        }
        return summaryText
    }

    /// Called on every GPS fix. Updates search region, remaining distance/ETA,
    /// turn-by-turn step progress, off-route recalculation, and auto-arrival.
    func updateOrigin(_ coordinate: CLLocationCoordinate2D) {
        origin = coordinate
        destinationSearch.updateRegion(center: coordinate)
        if phase == .previewing,
           previewRoutes.isEmpty,
           !isRouting,
           destinationCoordinate != nil {
            computeRoute(isRecalculation: false, requestAlternates: true)
        }
        guard hasRoute else { return }
        recomputeRemaining(from: coordinate)
        guard phase == .navigating else { return }
        advanceStepIfNeeded(from: coordinate)
        checkOffRouteAndRecalculate(from: coordinate)
        checkArrival(from: coordinate)
    }

    func selectCompletion(_ completion: MKLocalSearchCompletion) {
        destinationSearch.resolveCompletion(completion) { coordinate, name, subtitle in
            self.beginPreview(coordinate: coordinate, name: name, subtitle: subtitle)
        }
    }

    func setDestination(coordinate: CLLocationCoordinate2D, name: String, subtitle: String = "") {
        beginPreview(coordinate: coordinate, name: name, subtitle: subtitle)
    }

    func beginPreview(coordinate: CLLocationCoordinate2D, name: String, subtitle: String = "") {
        routeRequestGeneration &+= 1
        DestinationSearchHistory.add(
            name: name,
            subtitle: subtitle,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        destinationCoordinate = coordinate
        destinationName = name
        destinationSearch.reset()
        previewErrorMessage = nil
        previewRoutes = []
        selectedRouteID = nil
        steps = []
        currentStepIndex = 0
        approachedStepID = nil
        announcedStepID = nil
        voice.stop()
        isOffRoute = false
        phase = .previewing
        computeRoute(isRecalculation: false, requestAlternates: true)
    }

    func selectPreviewRoute(id: UUID) {
        guard phase == .previewing,
              let option = previewRoutes.first(where: { $0.id == id }) else { return }
        selectedRouteID = id
        applyPreviewSelection(option)
    }

    func confirmStartNavigation() {
        guard phase == .previewing, let option = selectedPreviewRoute else { return }
        phase = .navigating
        navigationStartedAt = Date()
        plannedCarTravelTime = option.expectedTravelTime
        plannedMotoTravelTime = option.motoTravelTime
        lastTimingResult = nil
        arrivalCandidateSince = nil
        applyRoute(
            coordinates: option.coordinates,
            distance: option.distanceMeters,
            carTravelTime: option.expectedTravelTime,
            motoTravelTime: option.motoTravelTime,
            steps: option.steps,
            isRecalculation: false
        )
        AppLogger.navigation.notice(
            "Navigation started car=\(Int(option.expectedTravelTime))s moto=\(Int(option.motoTravelTime))s"
        )
    }

    func cancelPreview() {
        clear()
    }

    func openInAppleMaps() {
        guard let destinationCoordinate else { return }
        let item = MapKitPlace.mapItem(coordinate: destinationCoordinate, name: destinationName)
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }

    func clear(stopVoice: Bool = true) {
        // When called from completeArrival, timing was already finalized.
        if navigationStartedAt != nil {
            finalizeTimingIfNeeded()
        }
        routeRequestGeneration &+= 1
        destinationCoordinate = nil
        destinationName = nil
        routeCoordinates = []
        phase = .idle
        previewRoutes = []
        selectedRouteID = nil
        previewErrorMessage = nil
        distanceRemaining = 0
        eta = nil
        steps = []
        currentStepIndex = 0
        distanceToNextManeuver = 0
        totalRouteDistance = 0
        totalTravelTime = 0
        plannedCarTravelTime = 0
        plannedMotoTravelTime = 0
        navigationStartedAt = nil
        arrivalCandidateSince = nil
        isRouting = false
        isOffRoute = false
        isRecalculating = false
        nearestRouteDistance = 0
        destinationSearch.reset()
        approachedStepID = nil
        announcedStepID = nil
        if stopVoice {
            voice.stop()
        }
        onRouteCleared?()
        AppLogger.navigation.notice("Navigation cleared")
    }

    func dismissTimingResult() {
        lastTimingResult = nil
    }

    static func formatDistance(_ meters: CLLocationDistance) -> String {
        NavigationRouteMath.formatDistance(meters)
    }

    private func finalizeTimingIfNeeded() {
        guard phase == .navigating,
              let started = navigationStartedAt,
              plannedCarTravelTime > 0
        else { return }

        let actual = Date().timeIntervalSince(started)
        guard actual >= 45 else { return }

        let result = NavTimingResult(
            distanceMeters: totalRouteDistance,
            carEstimate: plannedCarTravelTime,
            motoEstimate: plannedMotoTravelTime > 0 ? plannedMotoTravelTime : plannedCarTravelTime,
            actual: actual
        )
        MotoTravelEstimator.learn(from: result)
        lastTimingResult = result
        navigationStartedAt = nil
        AppLogger.navigation.notice(
            "Nav timing actual=\(Int(actual))s car=\(Int(result.carEstimate))s moto=\(Int(result.motoEstimate))s savedVsCar=\(Int(result.savedVersusCar))s"
        )
    }

    private func checkArrival(from coordinate: CLLocationCoordinate2D) {
        guard let destinationCoordinate else {
            arrivalCandidateSince = nil
            return
        }

        let toDestination = NavigationRouteMath.meters(from: coordinate, to: destinationCoordinate)
        if NavigationRouteMath.isArrivalCandidate(
            metersToDestination: toDestination,
            distanceRemaining: distanceRemaining,
            currentStepIndex: currentStepIndex,
            stepCount: steps.count,
            destinationThresholdMeters: Self.arrivalThresholdMeters,
            remainingMaxMeters: Self.arrivalRemainingMaxMeters
        ) {
            if arrivalCandidateSince == nil {
                arrivalCandidateSince = Date()
                AppLogger.navigation.debug(
                    "Arrival candidate dest=\(Int(toDestination))m remaining=\(Int(self.distanceRemaining))m"
                )
            }
            if let since = arrivalCandidateSince,
               Date().timeIntervalSince(since) >= Self.arrivalDwell {
                completeArrival()
            }
        } else {
            arrivalCandidateSince = nil
        }
    }

    private func completeArrival() {
        guard phase == .navigating else { return }
        arrivalCandidateSince = nil
        AppLogger.navigation.notice("Arrived at destination — ending navigation")
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        // Finalize timing before clear so the banner can show; then announce arrival.
        finalizeTimingIfNeeded()
        clear(stopVoice: false)
        voice.speak("You have arrived")
    }

    func computeRoute(isRecalculation: Bool, requestAlternates: Bool = false) {
        guard let origin else {
            if phase == .previewing, !isRecalculation {
                previewErrorMessage = "Waiting for your location…"
            }
            return
        }
        guard let destinationCoordinate else { return }
        routeRequestGeneration &+= 1
        let requestGeneration = routeRequestGeneration
        if isRecalculation {
            isRecalculating = true
        } else {
            isRouting = true
            previewErrorMessage = nil
        }

        let request = MKDirections.Request()
        request.source = MapKitPlace.mapItem(coordinate: origin)
        request.destination = MapKitPlace.mapItem(coordinate: destinationCoordinate)
        request.transportType = .automobile
        request.requestsAlternateRoutes = requestAlternates && !isRecalculation
        // Near-term departure asks MapKit for a traffic-aware automobile ETA.
        request.departureDate = Date()

        Task {
            let mkRoutes: [MKRoute]
            do {
                mkRoutes = try await MKDirections(request: request).calculate().routes
            } catch {
                AppLogger.navigation.error("Directions failed: \(error.localizedDescription, privacy: .public)")
                mkRoutes = []
            }
            guard self.routeRequestGeneration == requestGeneration else { return }
            if isRecalculation {
                guard self.phase == .navigating else { return }
            } else {
                guard self.phase == .previewing else { return }
            }
            if self.phase == .previewing, !isRecalculation {
                self.applyPreviewRoutes(mkRoutes)
            } else if let route = mkRoutes.first {
                let coordinates = route.polyline.coordinates
                let navSteps = Self.navSteps(from: route)
                let estimate = MotoTravelEstimator.estimate(
                    distanceMeters: route.distance,
                    carTravelTime: route.expectedTravelTime
                )
                self.applyRoute(
                    coordinates: coordinates,
                    distance: route.distance,
                    carTravelTime: estimate.carTravelTime,
                    motoTravelTime: estimate.motoTravelTime,
                    steps: navSteps,
                    isRecalculation: isRecalculation
                )
            } else {
                self.isRouting = false
                self.isRecalculating = false
                if self.phase == .previewing {
                    self.previewErrorMessage = "Couldn't find a driving route."
                }
            }
        }
    }
}
