import Foundation

enum BackendSettings {
    private static let baseURLKey = "backendBaseURL"

    /// Empty = cloud upload disabled. Set in UserDefaults, e.g. `http://192.168.1.10:8080`.
    static var baseURL: String {
        UserDefaults.standard.string(forKey: baseURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            ?? ""
    }

    static var isEnabled: Bool {
        !baseURL.isEmpty
    }

    static func setBaseURL(_ url: String) {
        UserDefaults.standard.set(url, forKey: baseURLKey)
    }
}
