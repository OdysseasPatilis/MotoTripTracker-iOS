import SwiftData
import SwiftUI

@main
struct MotoTripTrackerApp: App {
    @State private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootNavigationView()
                .environment(container)
                .environment(container.theme)
                .modelContainer(container.modelContainer)
        }
    }
}
