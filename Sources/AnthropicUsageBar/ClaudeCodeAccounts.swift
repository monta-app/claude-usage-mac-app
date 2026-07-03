import Foundation
import AppKit

enum CCLogin {
    private static func claudePath() -> String {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "claude"
    }

    /// Opens Terminal running `claude /login` so the user can switch which
    /// account Claude Code (and Conductor, etc.) use. Uses a `.command` file so
    /// no Automation permission is needed. The app never touches credentials.
    static func openLogin() {
        let claude = claudePath()
        let script = """
        #!/bin/bash
        clear
        echo "════════════════════════════════════════════════"
        echo "  Log in to the Claude account you want to use."
        echo "  Claude Code, Conductor, and this app will all"
        echo "  use whichever account you pick here."
        echo "════════════════════════════════════════════════"
        echo
        "\(claude)" /login
        echo
        echo "✅ Done — close this window. Claude Usage updates within a few minutes (or hit ↻)."

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
