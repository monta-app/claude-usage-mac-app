import SwiftUI
import AppKit

@main
struct AnthropicUsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AccountStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(store)
        } label: {
            Text(store.menuBarTitle)
        }
        .menuBarExtraStyle(.window)

        Window("Manage Accounts", id: "manage") {
            ManageAccountsView()
                .environmentObject(store)
                .frame(width: 460, height: 480)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon, no main window on launch.
        NSApp.setActivationPolicy(.accessory)

        // First launch: opt into "Launch at login" by default so the usage bar
        // is always there after a reboot. The user can turn it off from the
        // menu toggle at any time; we only auto-enable once.
        let defaults = UserDefaults.standard
        let key = "didInitLoginItem"
        if !defaults.bool(forKey: key) {
            LoginItem.shared.setEnabled(true)
            defaults.set(true, forKey: key)
        } else {
            LoginItem.shared.refresh()
        }
    }
}
