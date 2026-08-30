import SwiftUI

private struct AppNavigateKey: EnvironmentKey {
    static let defaultValue: (AppRoute) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Pushes an `AppRoute` onto the root `NavigationStack`.
    var appNavigate: (AppRoute) -> Void {
        get { self[AppNavigateKey.self] }
        set { self[AppNavigateKey.self] = newValue }
    }
}
