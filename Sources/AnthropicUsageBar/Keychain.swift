import Foundation
import Security

/// Stores each account's Admin API key in the macOS Keychain,
/// keyed by the account's UUID. The key is never written to disk in plaintext.
enum Keychain {
    /// Admin API keys (org cost tracking).
    static let adminService = "com.local.AnthropicUsageBar"
    /// Claude Code subscription tokens the app owns (per plan account).
    static let ccService = "com.local.AnthropicUsageBar.claudecode"

    static func save(key: String, for id: UUID, service: String = adminService) {
        delete(for: id, service: service)   // overwrite cleanly
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

    static func load(for id: UUID, service: String = adminService) -> String? {
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

    static func delete(for id: UUID, service: String = adminService) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }
}
