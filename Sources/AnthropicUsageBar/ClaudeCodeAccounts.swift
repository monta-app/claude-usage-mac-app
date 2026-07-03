import Foundation
import AppKit

/// One tracked account. `configDir == nil` is the **default** login
/// (`~/.claude`) — the one Claude Code and Conductor use. Extra accounts each
/// get their own config dir, so they're logged in independently and never
/// touch the default login or the Keychain.
struct ConfigAccount: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var configDir: String?   // nil = default ~/.claude
}

enum CCLogin {
    static func newConfigDir(for id: UUID) -> String {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ClaudeUsage/cc/\(id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.path
    }

    private static func claudePath() -> String {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "claude"
    }

    /// Opens Terminal running `claude /login` for a given config dir (nil =
    /// default). The browser login writes only into that dir's own session —
    /// it does not touch the Keychain or any other account. Uses a `.command`
    /// file so no Automation permission is needed.
    static func openLogin(configDir: String?) {
        let claude = claudePath()
        let exportLine = configDir.map { "export CLAUDE_CONFIG_DIR=\"\($0)\"" } ?? ""
        let which = configDir == nil
            ? "your DEFAULT account (used by Claude Code & Conductor)"
            : "THIS account (kept separate from your default)"
        let script = """
        #!/bin/bash
        \(exportLine)
        clear
        echo "════════════════════════════════════════════════"
        echo "  Log in to \(which)."
        echo "  Approve in the browser, then close this window."
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
