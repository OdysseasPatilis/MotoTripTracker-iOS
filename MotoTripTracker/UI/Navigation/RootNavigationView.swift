import SwiftUI

enum AppRoute: Hashable {
    case history
    case summary(UUID)
    case fullRoute(UUID)
}

struct RootNavigationView: View {
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        NavigationStack {
            RideTrackerView()
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .history:
                        RideHistoryView()
                    case .summary(let id):
                        RideSummaryView(tripID: id)
                    case .fullRoute(let id):
                        FullRouteView(tripID: id)
                    }
                }
        }
        .preferredColorScheme(theme.mode.colorScheme)
        .animation(.easeInOut(duration: 0.25), value: theme.mode)
    }
}
