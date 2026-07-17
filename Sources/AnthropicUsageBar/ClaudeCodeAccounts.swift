import Foundation
import AppKit

/// GUI-only: snapshot the CURRENT live login (macOS Keychain) into an account's
/// own config-dir file, WITHOUT logging in again. Runs in Terminal so its
/// Keychain read uses Terminal's own persistent "Always Allow". Resets the dir
/// to a clean file-only state so `claude` reads the file, not the Keychain.
///
/// The CLI doesn't use this — it runs `claude /login` inline under
/// `CLAUDE_CONFIG_DIR` instead (no Keychain involved, SSH-friendly).
enum CCLogin {
    /// Snapshot the current live login (macOS Keychain) into this account's own
    /// config-dir file, WITHOUT logging in again.
    static func captureCurrent(configDir: String) {
        let script = """
        #!/bin/bash
        DIR="\(configDir)"
        clear
        echo "Saving the account you're currently logged into…"
        CRED=$(security find-generic-password -s "Claude Code-credentials" -a "$(id -un)" -w 2>/dev/null)
        if [ -z "$CRED" ]; then
          echo "⚠️  Couldn't read the current login. If a Keychain prompt appears, click Always Allow, then re-run."
        else
          rm -rf "$DIR"; mkdir -p "$DIR"
          printf '%s' "$CRED" > "$DIR/.credentials.json"
          echo "✅ Saved. This account now has its own login and won't change when you switch Conductor."
        fi
        echo
        echo "Close this window; Claude Usage updates within a minute (or hit ↻)."

        """
        run(script)
    }

    private static func run(_ script: String) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-usage-\(UUID().uuidString).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch { NSLog("script write failed: \(error)") }
    }
}
