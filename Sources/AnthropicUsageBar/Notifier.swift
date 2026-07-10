import Foundation
import UserNotifications

/// Posts a local notification when an account's usage window hits 100%.
///
/// Alerts are **edge-triggered**: each (account, window) fires once when it
/// crosses into 100% and re-arms only after it drops back below, so a window
/// sitting at 100% across many 5-minute refreshes doesn't spam. The on/off
/// switch is persisted in `UserDefaults`.
@MainActor
final class Notifier: ObservableObject {
    static let shared = Notifier()

    private let enabledKey = "notificationsEnabled"

    /// User-facing on/off. Requesting auth on enable so the first toggle
    /// triggers the system permission prompt.
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: enabledKey)
            if isEnabled { requestAuthorization() }
        }
    }

    /// Windows currently known to be at 100% (keyed "accountID|windowID"), so we
    /// only notify on the low→100% transition.
    private var firedKeys: Set<String> = []

    private init() {
        // Default ON, but only actually alerts once the user grants permission.
        isEnabled = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
        // Assigning in init doesn't fire `didSet`, so ask for permission here
        // when enabled — otherwise a fresh install never prompts and alerts
        // silently never appear.
        if isEnabled { requestAuthorization() }
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Call after each refresh with the freshest states. Fires for any window
    /// that just reached 100%.
    func evaluate(accounts: [ConfigAccount], states: [UUID: ClaudeCode.State], title: (ConfigAccount) -> String) {
        guard isEnabled else { firedKeys.removeAll(); return }

        for account in accounts {
            guard case .ok(let windows)? = states[account.id] else { continue }
            for w in windows {
                let key = "\(account.id.uuidString)|\(w.id)"
                if w.fraction >= 1.0 {
                    if !firedKeys.contains(key) {
                        firedKeys.insert(key)
                        post(account: title(account), window: w.label)
                    }
                } else {
                    firedKeys.remove(key)   // re-arm once it drops below 100%
                }
            }
        }
    }

    private func post(account: String, window: String) {
        let content = UNMutableNotificationContent()
        content.title = "\(account) is out of usage"
        content.body = "\(window) has hit 100%. New requests will be blocked until it resets."
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
