import Foundation
import AppKit

/// A registered Claude Code account. Its login snapshot lives in the Keychain
/// (keyed by `id`); `label` is captured from the CLI at save time for display.
struct SwitchAccount: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var label: String
}

enum CCLogin {
    private static func claudePath() -> String {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "claude"
    }

    /// Opens Terminal running `claude /login` (default login). Used to sign in
    /// to an account so it can then be registered/snapshotted by the app.
    /// Uses a `.command` file so no Automation permission is needed.
    static func openLogin() {
        let claude = claudePath()
        let script = """
        #!/bin/bash
        clear
        echo "════════════════════════════════════════════════"
        echo "  Log in to the Claude account you want to add."
        echo "  Approve in the browser, then come back to"
        echo "  Claude Usage and click \\"Add current login\\"."
        echo "════════════════════════════════════════════════"
        echo
        "\(claude)" /login
        echo
        echo "✅ Logged in. Return to Claude Usage → Add current login."

        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-usage-login-\(UUID().uuidString).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch { NSLog("login script write failed: \(error)") }
    }
}
