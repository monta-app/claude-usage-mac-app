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
    }
}
