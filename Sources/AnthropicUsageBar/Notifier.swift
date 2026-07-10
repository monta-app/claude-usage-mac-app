import Foundation
import AppKit

/// Posts a notification when an account's usage window hits 100%.
///
/// Delivery uses `osascript display notification` rather than
/// `UNUserNotificationCenter`: this app is ad-hoc signed and run from an
/// arbitrary folder, so it never registers with Notification Center and
/// `UNUserNotificationCenter` silently drops everything. Shelling out to
/// osascript needs no code-signing or entitlements and works for local tools.
///
/// Alerts are **edge-triggered**: each (account, window) fires once when it
/// crosses into 100% and re-arms only after it drops below, so a window sitting
/// at 100% across many refreshes doesn't spam. On/off persists in UserDefaults.
@MainActor
final class Notifier: ObservableObject {
    static let shared = Notifier()

    private let enabledKey = "notificationsEnabled"

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: enabledKey)
            // Turning it on fires a test banner so the user can confirm alerts
            // actually reach Notification Center on their machine.
            if isEnabled && !oldValue {
                deliver(title: "Claude Usage — alerts on",
                        body: "You'll get a notification when an account hits 100% usage.",
                        sound: "Ping")
            }
        }
    }

    /// Windows currently known to be at 100% (keyed "accountID|windowID").
    private var firedKeys: Set<String> = []

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Call after each refresh. Fires for any window that just reached 100%.
    func evaluate(accounts: [ConfigAccount], states: [UUID: ClaudeCode.State], title: (ConfigAccount) -> String) {
        guard isEnabled else { firedKeys.removeAll(); return }

        for account in accounts {
            guard case .ok(let windows)? = states[account.id] else { continue }
            for w in windows {
                let key = "\(account.id.uuidString)|\(w.id)"
                if w.fraction >= 1.0 {
                    if !firedKeys.contains(key) {
                        firedKeys.insert(key)
                        deliver(title: "\(title(account)) is out of usage",
                                body: "\(w.label) has hit 100%. New requests are blocked until it resets.",
                                sound: "Basso")
                    }
                } else {
                    firedKeys.remove(key)   // re-arm once it drops below 100%
                }
            }
        }
    }

    // MARK: Delivery

    private func deliver(title: String, body: String, sound: String) {
        let script = "display notification \(quote(body)) with title \(quote(title)) sound name \(quote(sound))"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        try? task.run()
    }

    /// AppleScript string literal: wrap in quotes and escape `\` and `"`.
    private func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
