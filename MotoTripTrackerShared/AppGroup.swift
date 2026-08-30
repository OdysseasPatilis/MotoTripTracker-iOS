import Foundation

/// App Group shared by the main app and the widget / Live Activity extension.
/// `nonisolated` so widget snapshot I/O works under default MainActor isolation.
nonisolated enum AppGroup {
    static let identifier = "group.com.odys.MotoTripTracker"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }
}
