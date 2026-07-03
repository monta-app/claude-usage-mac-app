import Foundation
import Security

/// Keychain helpers. Account snapshots and any app secrets are keyed by the
/// account's UUID; nothing is written to disk in plaintext.
enum Keychain {
    /// Where the app stores each registered account's login snapshot.
    static let credService = "com.local.AnthropicUsageBar.cred"

    static func save(key: String, for id: UUID, service: String = credService) {
        delete(for: id, service: service)
        guard let data = key.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(for id: UUID, service: String = credService) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    static func delete(for id: UUID, service: String = credService) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Reads and writes the **live Claude Code login** — a single generic-password
/// item (`Claude Code-credentials`) that holds the OAuth JSON the CLI (and
/// Conductor, etc.) authenticate with. Swapping accounts = replacing this
/// item's value with a previously-saved snapshot.
///
/// Because the item was created by another app, the first read/write triggers a
/// macOS Keychain prompt — click **Always Allow**.
enum ClaudeCredential {
    static let service = "Claude Code-credentials"

    /// The current login blob (raw JSON) and the item's account attribute.
    static func read() -> (account: String, data: Data)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let dict = result as? [String: Any],
              let data = dict[kSecValueData as String] as? Data else { return nil }
        let acct = (dict[kSecAttrAccount as String] as? String) ?? NSUserName()
        return (acct, data)
    }

    /// Replace the live login with `data`. Updates the existing item in place
    /// (preserving its account attribute) or adds one if none exists.
    /// Returns true on success. Never writes empty/invalid data.
    @discardableResult
    static func write(_ data: Data) -> Bool {
        guard isValid(data) else { return false }
        let account = read()?.account ?? NSUserName()
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(match as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var add = match
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    /// Guard: only accept blobs that look like a Claude Code credential.
    static func isValid(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return obj["claudeAiOauth"] != nil
    }
}
