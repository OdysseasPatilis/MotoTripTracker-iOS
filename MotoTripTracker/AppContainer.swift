import Foundation
import SwiftData
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
        self.theme = ThemeStore()

        locationService.onLocationUpdate = { [weak self] location in
            guard let self else { return }
            self.tripManager.onLocationUpdate(location)
            self.speedLimitService.refresh(for: location)
            self.navigationService.updateOrigin(location.coordinate)
            self.pushLiveActivityUpdate()
        }

        // Seed Home Screen widgets from existing history.
        RideWidgetSnapshotPublisher.publish(from: repository)
        AppLogger.app.info("AppContainer ready (SwiftData + services wired)")
    }

    func startRide() {
        AppLogger.app.notice("Start ride requested")
        locationService.requestAuthorization()
        speedLimitService.reset()
        tripManager.startTrip()
        locationService.startUpdating()
        if let location = locationService.lastLocation {
            speedLimitService.refresh(for: location)
        }
        RideLiveActivityController.shared.start()
        pushLiveActivityUpdate(force: true)
    }

    func pauseRide() {
        AppLogger.app.notice("Pause ride requested")
        tripManager.pauseTrip()
        pushLiveActivityUpdate(force: true)
    }

    func resumeRide() {
        AppLogger.app.notice("Resume ride requested")
        tripManager.resumeTrip()
        locationService.startUpdating()
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
        RideLiveActivityController.shared.end()
        RideWidgetSnapshotPublisher.publish(from: repository)
        return saved
    }

    private func pushLiveActivityUpdate(force: Bool = false) {
        let session = tripManager.sessionState
        guard session.isActive else { return }
        let nav = navigationService
        RideLiveActivityController.shared.update(
            speedKmh: session.stats.speed,
            speedLimitKmh: speedLimitService.effectiveLimitKmh,
            distanceKm: session.stats.distanceKm,
            movingTimeSeconds: session.stats.movingTime,
            isPaused: session.isPaused,
            navigationSummary: nav.hasDestination ? nav.summaryText : "",
            force: force
        )
    }
}
