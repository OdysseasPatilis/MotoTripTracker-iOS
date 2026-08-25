import SwiftData
import SwiftUI
import os

@main
struct MotoTripTrackerApp: App {
    @State private var container = AppContainer()

    init() {
        AppLogger.app.notice("MotoTripTracker launching")
    }

    var body: some Scene {
        WindowGroup {
            RootNavigationView()
                .environment(container)
                .environment(container.theme)
                .modelContainer(container.modelContainer)
        }
    }
}
