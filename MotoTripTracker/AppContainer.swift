import Foundation
import SwiftData
import UIKit
import WidgetKit
import os
import CoreLocation

@Observable
@MainActor
final class AppContainer {
    let modelContainer: ModelContainer
    let repository: TripRepository
    let tripManager: TripManager
    let locationService: LocationService
    let speedLimitService: SpeedLimitService
    let navigationService: NavigationService
    let fuelService: FuelService
    let petrolPreferences: PetrolPreferences
    let routeWeatherService: RouteWeatherService
    let theme: ThemeStore

    init(inMemory: Bool = false) {
        let schema = Schema([Trip.self, RoutePoint.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        let container = try! ModelContainer(for: schema, configurations: [configuration])
        self.modelContainer = container

        let repository = TripRepository(modelContext: container.mainContext)
        let speedLimitService = SpeedLimitService()
        self.repository = repository
        self.tripManager = TripManager(repository: repository)
        self.locationService = LocationService()
        self.speedLimitService = speedLimitService
        self.navigationService = NavigationService()
        self.fuelService = FuelService()
        self.petrolPreferences = PetrolPreferences()
        self.routeWeatherService = RouteWeatherService()
        self.theme = ThemeStore()

        navigationService.onRouteApplied = { [weak self] coordinates, travelTime in
            self?.routeWeatherService.refreshForRoute(coordinates: coordinates, travelTime: travelTime)
        }
        navigationService.onRouteCleared = { [weak self] in
            self?.routeWeatherService.clear()
        }

        locationService.onLocationUpdate = { [weak self] location in
            guard let self else { return }
            self.tripManager.onLocationUpdate(location)
            self.speedLimitService.refresh(for: location)
            self.navigationService.updateOrigin(location.coordinate)
            let session = self.tripManager.sessionState
            if session.isActive, !session.isPaused {
                self.fuelService.updateConsumedDistance(tripDistanceKm: session.stats.distanceKm)
            }
            if self.navigationService.hasRoute {
                self.routeWeatherService.refreshAhead(
                    progressFraction: self.navigationService.routeProgressFraction
                )
            }
            self.pushLiveActivityUpdate()
        }

        // Widget snapshot can wait until after first frame — reloadAllTimelines is costly.
        Task { @MainActor in
            repository.recoverOrphanedTrips()
            repository.repairUndercountedTripTimings()
            RideWidgetSnapshotPublisher.publish(from: repository)
            RideLiveActivityController.shared.endStaleActivitiesIfNeeded()
        }
        AppLogger.app.info("AppContainer ready (SwiftData + services wired)")
    }

    /// Touch frameworks that are expensive on first use so History / destination
    /// search don't pay the cold-start cost when the user taps them.
    func warmUpForFirstInteraction() {
        _ = repository.allTrips()
        navigationService.warmUpSearchCompleter()
        AppLogger.app.debug("First-interaction warm-up complete")
    }

    /// Prevent auto-lock while a ride session is active (including paused).
    func syncKeepScreenAwake() {
        UIApplication.shared.isIdleTimerDisabled = tripManager.sessionState.isActive
    }

    func startRide() {
        AppLogger.app.notice("Start ride requested")
        locationService.requestAlwaysForRideRecording()
        speedLimitService.reset()
        fuelService.resetRideConsumption()
        tripManager.startTrip()
        syncKeepScreenAwake()
        locationService.startRideUpdating()
        if let location = locationService.lastLocation {
            speedLimitService.refresh(for: location)
            navigationService.updateOrigin(location.coordinate)
        }
        RideLiveActivityController.shared.start()
        pushLiveActivityUpdate(force: true)
        if !locationService.hasAlwaysAuthorization {
            AppLogger.app.warning(
                "Ride started without Always location — recording will stop when the screen locks"
            )
        }
    }

    /// Call when the app returns to the foreground during an active ride.
    func resumeBackgroundTrackingIfNeeded() {
        guard tripManager.sessionState.isActive else { return }
        syncKeepScreenAwake()
        locationService.requestAlwaysForRideRecording()
        locationService.startRideUpdating()
        if let location = locationService.lastLocation {
            speedLimitService.refresh(for: location)
            navigationService.updateOrigin(location.coordinate)
        }
        pushLiveActivityUpdate(force: true)
    }

    func pauseRide() {
        AppLogger.app.notice("Pause ride requested")
        tripManager.pauseTrip()
        syncKeepScreenAwake()
        pushLiveActivityUpdate(force: true)
    }

    func resumeRide() {
        AppLogger.app.notice("Resume ride requested")
        tripManager.resumeTrip()
        syncKeepScreenAwake()
        locationService.startRideUpdating()
        if let location = locationService.lastLocation {
            speedLimitService.refresh(for: location)
        }
        pushLiveActivityUpdate(force: true)
    }

    /// Returns `false` when the ride was discarded for being shorter than the minimum distance.
    @discardableResult
    func stopRide() -> Bool {
        AppLogger.app.notice("Stop ride requested")
        let saved = tripManager.stopTrip()
        syncKeepScreenAwake()
        // Drop background GPS intent; keep foreground updates for the dashboard map.
        locationService.startUpdating()
        RideLiveActivityController.shared.end()
        RideWidgetSnapshotPublisher.publish(from: repository)
        return saved
    }

    private func pushLiveActivityUpdate(force: Bool = false) {
        let session = tripManager.sessionState
        guard session.isActive else { return }
        let nav = navigationService
        let summary: String
        if nav.hasDestination {
            summary = nav.guidanceSummary
        } else if fuelService.isLowFuel {
            summary = "Low fuel · \(fuelService.rangeSummary)"
        } else {
            summary = ""
        }
        RideLiveActivityController.shared.update(
            speedKmh: session.stats.speed,
            speedLimitKmh: speedLimitService.effectiveLimitKmh,
            distanceKm: session.stats.distanceKm,
            movingTimeSeconds: session.stats.movingTime,
            isPaused: session.isPaused,
            navigationSummary: summary,
            force: force
        )
    }
}
