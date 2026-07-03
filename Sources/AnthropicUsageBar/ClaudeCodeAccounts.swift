import Foundation
import AppKit

/// An additional Claude Code login, isolated in its own config directory so it
/// doesn't clash with your primary `~/.claude` login. `CLAUDE_CONFIG_DIR`
/// points the CLI at this dir, giving a fully independent subscription session.
struct CCAccount: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var configDir: String
    /// Member email used to filter the Claude Code Analytics API for this
    /// account's per-member spend. Optional so older saved accounts decode.
    var memberEmail: String? = nil
}

enum CCLogin {
    /// Directory where the app keeps per-account config dirs.
    static func newConfigDir(for id: UUID) -> String {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AnthropicUsageBar/cc/\(id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.path
    }

    /// Opens Terminal running just `claude setup-token` so the user can
    /// generate a long-lived token and copy it into the app (one time, ever).
    static func openSetupToken() {
        let claude = claudePath()
        let script = """
        #!/bin/bash
        clear
        echo "════════════════════════════════════════════════"
        echo "  Generating a long-lived Claude Code token."
        echo "  Approve in the browser, then COPY the token it"
        echo "  prints and paste it into Anthropic Usage."
        echo "  (This token does not expire — you only do this once.)"
        echo "════════════════════════════════════════════════"
        echo
        "\(claude)" setup-token

        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anthropic-usage-setup-token-\(UUID().uuidString).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch { NSLog("setup-token script write failed: \(error)") }
    }

    private static func claudePath() -> String {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "claude"
    }

    /// Opens Terminal running `claude /login` with CLAUDE_CONFIG_DIR set to this
    /// account's dir, by writing an executable `.command` script and asking
    /// Finder/Terminal to open it. This needs **no** Automation permission
    /// (unlike AppleScript-driving Terminal), so the button "just works".
    /// The user completes the browser OAuth; the CLI stores its own session in
    /// that dir — the app captures nothing.
    /// `configDir == nil` logs into the default (~/.claude) — your Primary
    /// Claude Code login. A path logs into an isolated extra account.
    static func openLogin(configDir: String?) {
        let claude = claudePath()
        let exportLine = configDir.map { "export CLAUDE_CONFIG_DIR=\"\($0)\"" } ?? ""
        let script = """
        #!/bin/bash
        \(exportLine)
        clear
        echo "════════════════════════════════════════════════"
        echo "  Log in to the Max account for THIS plan."
        echo "  A browser window will open — approve it there."
        echo "  When it says you're logged in, close this window."
        echo "════════════════════════════════════════════════"
        echo
        "\(claude)" /login
        echo
        echo "✅ Done — you can close this window. The app updates within a minute."

        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anthropic-usage-login-\(UUID().uuidString).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            NSLog("login script write failed: \(error)")
        }
    }
}
