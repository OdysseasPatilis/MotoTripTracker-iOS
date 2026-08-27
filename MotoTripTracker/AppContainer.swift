import Foundation
import SwiftData
import os

@Observable
@MainActor
final class AppContainer {
    let modelContainer: ModelContainer
    let repository: TripRepository
    let tripManager: TripManager
    let locationService: LocationService
    let speedLimitService: SpeedLimitService
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
        self.theme = ThemeStore()

        locationService.onLocationUpdate = { [weak tripManager, weak speedLimitService] location in
            tripManager?.onLocationUpdate(location)
            speedLimitService?.refresh(for: location)
        }

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
    }

    func pauseRide() {
        AppLogger.app.notice("Pause ride requested")
        tripManager.pauseTrip()
        // Keep GPS running so the dashboard signal indicator stays live.
    }

    func resumeRide() {
        AppLogger.app.notice("Resume ride requested")
        tripManager.resumeTrip()
        locationService.startUpdating()
        if let location = locationService.lastLocation {
            speedLimitService.refresh(for: location)
        }
    }

    /// Returns `false` when the ride was discarded for being shorter than the minimum distance.
    @discardableResult
    func stopRide() -> Bool {
        AppLogger.app.notice("Stop ride requested")
        let saved = tripManager.stopTrip()
        // Keep GPS running while the tracker screen is visible.
        return saved
    }
}
