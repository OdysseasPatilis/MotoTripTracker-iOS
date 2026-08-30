import SwiftData
import SwiftUI
import os

@main
struct MotoTripTrackerApp: App {
    @State private var container = AppContainer()
    @State private var showSplash = true

    init() {
        AppLogger.app.notice("MotoTripTracker launching")
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                // Keep the real UI mounted (opacity 1) under the splash so MapKit,
                // SwiftData, and navigation warm up during the intro instead of
                // on the first History / destination tap.
                RootNavigationView()
                    .environment(container)
                    .environment(container.theme)
                    .modelContainer(container.modelContainer)

                if showSplash {
                    SplashView {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showSplash = false
                        }
                    }
                    .transition(.opacity)
                    .zIndex(1)
                }
            }
            .preferredColorScheme(container.theme.mode.colorScheme)
            .task {
                container.warmUpForFirstInteraction()
            }
        }
    }
}
