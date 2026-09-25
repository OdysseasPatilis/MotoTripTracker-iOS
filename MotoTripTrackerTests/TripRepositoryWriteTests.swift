import Foundation
import SwiftData
import Testing
@testable import MotoTripTracker

@MainActor
struct TripRepositoryWriteTests {
    private let t0: TimeInterval = 1_000_000

    @Test func renameIsVisibleOnMainContextAfterReturning() async throws {
        let container = try makeContainer()
        let repo = TripRepository(modelContext: container.mainContext, container: container)
        let id = repo.startNewTrip(startTime: t0)
        await repo.waitForPendingWrites()

        await repo.renameTrip(id: id, title: "Coastal loop")

        #expect(repo.fetchTrip(id: id)?.title == "Coastal loop")
    }

    @Test func favoriteIsVisibleOnMainContextAfterReturning() async throws {
        let container = try makeContainer()
        let repo = TripRepository(modelContext: container.mainContext, container: container)
        let id = repo.startNewTrip(startTime: t0)
        await repo.waitForPendingWrites()

        await repo.toggleFavorite(id: id)

        #expect(repo.fetchTrip(id: id)?.isFavorite == true)
    }

    @Test func appContainerOwnsPetrolStationFinder() {
        let app = AppContainer(inMemory: true)
        let first = app.petrolStationFinder
        let second = app.petrolStationFinder
        #expect(first === second)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Trip.self, RoutePoint.self])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }
}
