import Foundation

enum BackendUserIdStore {
    private static let userIdKey = "mototrip_backend_user_id"

    static func getOrCreate() -> String {
        if let existing = UserDefaults.standard.string(forKey: userIdKey), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: userIdKey)
        return id
    }
}
