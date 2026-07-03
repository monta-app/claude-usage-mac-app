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

    /// Opens Terminal, logs in, and **captures the login into this account's own
    /// `.credentials.json` file** so the account becomes self-contained and
    /// independent of the shared macOS Keychain. This is what lets two accounts
    /// stay authenticated at once: each lives in its own file, not the one
    /// shared keychain slot. Uses a `.command` file (no Automation permission).
    /// For the default account (configDir == nil) it only logs in — no capture.
    static func openLogin(configDir: String?) {
        let claude = claudePath()
        let capture: String
        if let dir = configDir {
            // After login, copy the freshly-written keychain token into this
            // dir's file, then it reads from the file forever (independent).
            capture = """
            echo
            echo "Saving this account so it stays separate…"
            mkdir -p "\(dir)"
            CRED=$(security find-generic-password -s "Claude Code-credentials" -a "$(id -un)" -w 2>/dev/null)
            if [ -z "$CRED" ] && [ -f "$CLAUDE_CONFIG_DIR/.credentials.json" ]; then
              CRED=$(cat "$CLAUDE_CONFIG_DIR/.credentials.json")
            fi
            if [ -n "$CRED" ]; then
              printf '%s' "$CRED" > "\(dir)/.credentials.json"
              echo "✅ Saved. This account is now independent."
            else
              echo "⚠️  Could not save the token — click Always Allow if a Keychain prompt appears, then re-run."
            fi
            """
        } else {
            capture = "echo\necho \"✅ Done — this is your default account.\""
        }
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
        echo "  Approve in the browser."
        echo "════════════════════════════════════════════════"
        echo
        "\(claude)" /login
        \(capture)
        echo
        echo "Close this window. Claude Usage updates within a few minutes (or hit ↻)."

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
