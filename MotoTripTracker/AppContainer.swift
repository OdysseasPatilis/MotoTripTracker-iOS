import Foundation
import SwiftData

@Observable
@MainActor
final class AppContainer {
    let modelContainer: ModelContainer
    let repository: TripRepository
    let tripManager: TripManager
    let locationService: LocationService
    let theme: ThemeStore

    init(inMemory: Bool = false) {
        let schema = Schema([Trip.self, RoutePoint.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        let container = try! ModelContainer(for: schema, configurations: [configuration])
        self.modelContainer = container

        let repository = TripRepository(modelContext: container.mainContext)
        self.repository = repository
        self.tripManager = TripManager(repository: repository)
        self.locationService = LocationService()
        self.theme = ThemeStore()

        locationService.onLocationUpdate = { [weak tripManager] location in
            tripManager?.onLocationUpdate(location)
        }
    }

    func startRide() {
        locationService.requestAuthorization()
        tripManager.startTrip()
        locationService.startUpdating()
    }

    func pauseRide() {
        tripManager.pauseTrip()
        locationService.stopUpdating()
    }

    func resumeRide() {
        tripManager.resumeTrip()
        locationService.startUpdating()
    }

    func stopRide() {
        tripManager.stopTrip()
        locationService.stopUpdating()
    }
}
