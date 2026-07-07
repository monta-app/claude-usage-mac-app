import Foundation
import ServiceManagement
import Combine

/// Thin wrapper over `SMAppService.mainApp` so the app can register/unregister
/// itself as a Login Item (auto-start at login) from a SwiftUI toggle.
@MainActor
final class LoginItem: ObservableObject {
    static let shared = LoginItem()

    /// Mirrors the current registration state so a `Toggle` can bind to it.
    @Published var isEnabled: Bool

    private init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Re-read the real system state (it can change outside the app, e.g. via
    /// System Settings → General → Login Items).
    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Register or unregister as a login item. Returns nil on success, or an
    /// error message on failure.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
            return nil
        } catch {
            // Keep the toggle in sync with reality if the call failed.
            refresh()
            return error.localizedDescription
        }
    }
}
