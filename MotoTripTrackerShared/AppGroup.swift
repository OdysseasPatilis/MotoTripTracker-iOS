import Foundation

/// App Group shared by the main app and the widget / Live Activity extension.
enum AppGroup {
    static let identifier = "group.com.odys.MotoTripTracker"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }
}
