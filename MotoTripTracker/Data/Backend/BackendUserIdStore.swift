import Foundation
import os

/// Anonymous rider identity for cloud sync.
/// Prefers a server-issued profile id from `POST /v1/profiles`; local-only UUIDs
/// from older builds are replaced on the next successful registration.
enum BackendUserIdStore {
    private static let userIdKey = "mototrip_backend_user_id"
    private static let displayNameKey = "mototrip_backend_display_name"
    private static let serverSyncedKey = "mototrip_backend_profile_server_synced"
    private static let defaultDisplayName = "Rider"

    static var cachedProfileId: String? {
        guard UserDefaults.standard.bool(forKey: serverSyncedKey) else { return nil }
        let id = UserDefaults.standard.string(forKey: userIdKey) ?? ""
        return id.isEmpty ? nil : id
    }

    static var displayName: String {
        let name = UserDefaults.standard.string(forKey: displayNameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? defaultDisplayName : name
    }

    static func setDisplayNameLocal(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed.isEmpty ? defaultDisplayName : trimmed, forKey: displayNameKey)
    }

    /// Returns a server profile id, creating one via REST when needed.
    static func ensureServerProfile() async throws -> String {
        guard BackendSettings.isEnabled else {
            throw ProfileError.backendDisabled
        }
        if let existing = cachedProfileId {
            return existing
        }

        let name = displayName
        guard let url = URL(string: "\(BackendSettings.baseURL)/v1/profiles") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(CreateProfileBody(displayName: name))
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw ProfileError.http(http.statusCode)
        }

        let user = try JSONDecoder().decode(ProfileUser.self, from: data)
        UserDefaults.standard.set(user.id, forKey: userIdKey)
        UserDefaults.standard.set(user.displayName, forKey: displayNameKey)
        UserDefaults.standard.set(true, forKey: serverSyncedKey)
        AppLogger.app.notice("Server profile registered id=\(user.id.prefix(8), privacy: .public)")
        return user.id
    }

    /// Creates or patches the server profile so `name` is the display name.
    @discardableResult
    static func updateDisplayName(_ name: String) async throws -> String {
        guard BackendSettings.isEnabled else {
            throw ProfileError.backendDisabled
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProfileError.blankDisplayName
        }
        setDisplayNameLocal(trimmed)

        if cachedProfileId == nil {
            _ = try await ensureServerProfile()
            return displayName
        }

        let id = cachedProfileId!
        guard let url = URL(string: "\(BackendSettings.baseURL)/v1/profiles/\(id)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(UpdateProfileBody(displayName: trimmed))
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw ProfileError.http(http.statusCode)
        }

        let user = try JSONDecoder().decode(ProfileUser.self, from: data)
        UserDefaults.standard.set(user.displayName, forKey: displayNameKey)
        return user.displayName
    }

    enum ProfileError: LocalizedError {
        case backendDisabled
        case blankDisplayName
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .backendDisabled:
                "Backend URL not configured"
            case .blankDisplayName:
                "Display name must not be blank"
            case .http(let code):
                "Profile request failed (HTTP \(code))"
            }
        }
    }

    private struct CreateProfileBody: Encodable {
        let displayName: String
    }

    private struct UpdateProfileBody: Encodable {
        let displayName: String
    }

    private struct ProfileUser: Decodable {
        let id: String
        let displayName: String
    }
}
