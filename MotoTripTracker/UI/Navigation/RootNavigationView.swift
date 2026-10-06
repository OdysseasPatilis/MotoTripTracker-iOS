import SwiftData
import SwiftUI

enum AppRoute: Hashable {
    case history
    case leaderboard
    case summary(UUID)
    case fullRoute(UUID)
}

struct RootNavigationView: View {
    @Environment(ThemeStore.self) private var theme
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            RideTrackerView()
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .history:
                        RideHistoryView()
                    case .leaderboard:
                        RideLeaderboardView()
                    case .summary(let id):
                        RideSummaryView(tripID: id)
                    case .fullRoute(let id):
                        FullRouteView(tripID: id)
                    }
                }
        }
        .environment(\.appNavigate) { path.append($0) }
        .environment(\.dashboardIsVisible, path.isEmpty)
        .tint(theme.palette.neonGreen)
        .preferredColorScheme(theme.mode.colorScheme)
        .animation(.easeInOut(duration: 0.25), value: theme.mode)
    }
}

private struct DashboardIsVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False while History, Summary, or another pushed screen covers the live map.
    var dashboardIsVisible: Bool {
        get { self[DashboardIsVisibleKey.self] }
        set { self[DashboardIsVisibleKey.self] = newValue }
    }
}

#Preview {
    let app = AppContainer(inMemory: true)
    RootNavigationView()
        .environment(app)
        .environment(app.theme)
        .modelContainer(app.modelContainer)
}
