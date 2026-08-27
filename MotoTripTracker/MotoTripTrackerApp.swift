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
                RootNavigationView()
                    .environment(container)
                    .environment(container.theme)
                    .modelContainer(container.modelContainer)
                    .opacity(showSplash ? 0 : 1)

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
        }
    }
}
