import Foundation

/// Manages a per-account file-based Claude login (`<configDir>/.credentials.json`)
/// so the account is independent of the shared macOS Keychain. The app keeps
/// the token alive by refreshing it via the OAuth refresh grant and writing the
/// new token back to the file — this is what lets a second account stay logged
/// in without touching the Keychain or being clobbered by Conductor.
enum CredentialFile {
    /// Claude Code's public OAuth client id + token endpoint.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!

    static func path(_ configDir: String) -> String { configDir + "/.credentials.json" }

    static func exists(_ configDir: String) -> Bool {
        FileManager.default.fileExists(atPath: path(configDir))
    }

    private static func readOAuth(_ configDir: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path(configDir)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any] else { return nil }
        return oauth
    }

    /// The current OAuth access token for this login, if present. Used to read
    /// usage directly from the HTTP endpoint (robust to CLI output changes).
    static func accessToken(_ configDir: String) -> String? {
        (readOAuth(configDir)?["accessToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Refresh the file's token if it's within `window` seconds of expiry (or
    /// already expired). Best-effort: on any failure the existing file is kept.
    /// Returns true if a refresh was performed and written.
    @discardableResult
    static func refreshIfNeeded(_ configDir: String, window: TimeInterval = 600) async -> Bool {
        guard let data = FileManager.default.contents(atPath: path(configDir)),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var oauth = root["claudeAiOauth"] as? [String: Any],
              let refresh = oauth["refreshToken"] as? String, !refresh.isEmpty
        else { return false }

        let expMs = (oauth["expiresAt"] as? Double) ?? Double((oauth["expiresAt"] as? Int) ?? 0)
        let expiresAt = expMs / 1000.0
        if expiresAt - Date().timeIntervalSince1970 > window { return false }   // still fresh

        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 20

        guard let (respData, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let access = json["access_token"] as? String
        else { return false }

        oauth["accessToken"] = access
        if let nr = json["refresh_token"] as? String, !nr.isEmpty { oauth["refreshToken"] = nr }
        if let expIn = (json["expires_in"] as? Double) ?? Double((json["expires_in"] as? Int) ?? 0) as Double?, expIn > 0 {
            oauth["expiresAt"] = (Date().timeIntervalSince1970 + expIn) * 1000.0
        }
        root["claudeAiOauth"] = oauth
        guard let out = try? JSONSerialization.data(withJSONObject: root) else { return false }
        try? out.write(to: URL(fileURLWithPath: path(configDir)))
        return true
    }
}
