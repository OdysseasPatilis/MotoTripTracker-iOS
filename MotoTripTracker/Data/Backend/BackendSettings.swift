import Foundation

enum BackendSettings {
    private static let baseURLKey = "backendBaseURL"

    /// Empty = cloud upload disabled. Set in UserDefaults, e.g. `http://192.168.1.10:8080`.
    static var baseURL: String {
        normalize(UserDefaults.standard.string(forKey: baseURLKey) ?? "")
    }

    static var isEnabled: Bool {
        !baseURL.isEmpty
    }

    static func setBaseURL(_ url: String) {
        UserDefaults.standard.set(normalize(url), forKey: baseURLKey)
    }

    /// Ensures a scheme is present — bare `192.168.x.x:8080` is not a valid HTTP URL for URLSession.
    static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") {
            value.removeLast()
        }
        guard !value.isEmpty else { return "" }

        if value.contains("://") {
            return value
        }
        return "http://\(value)"
    }

    /// Whether the running app bundle allows cleartext HTTP (for diagnostics).
    static var allowsArbitraryLoadsInBundle: Bool {
        guard let ats = Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any] else {
            return false
        }
        // Note: if NSAllowsLocalNetworking is also present, iOS ignores NSAllowsArbitraryLoads.
        if ats["NSAllowsLocalNetworking"] != nil, ats["NSAllowsArbitraryLoads"] as? Bool == true {
            return false
        }
        return ats["NSAllowsArbitraryLoads"] as? Bool == true
    }
}
