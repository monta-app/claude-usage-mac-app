import Foundation
import AppKit

/// A tracked account. Every account is **file-based**: its login lives in its
/// own `<configDir>/.credentials.json`, captured from a live login and kept
/// fresh by the app. Nothing reads the shared macOS Keychain, so switching
/// Conductor/Claude Code never affects what the app shows.
struct ConfigAccount: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var configDir: String
    /// Optional daily auto-prime schedule. nil / disabled = off.
    var schedule: PrimeSchedule?
}

/// Auto-prime the 5h window on a daily schedule. The rule: within the active
/// window (`start` … `start + windowHours`), whenever no 5h block is running,
/// start one. This both kicks off the day at `start` AND restarts a fresh block
/// ASAP after the previous one runs out — while doing nothing when you're
/// already working (your own messages keep the block alive, so it only fills gaps).
struct PrimeSchedule: Codable, Equatable {
    var enabled: Bool = false
    var startMinutes: Int = 8 * 60   // minutes past local midnight
    var windowHours: Int = 9         // keep chaining for this long after start
    var weekdaysOnly: Bool = true

    /// "8:00" style label for the start time.
    var startLabel: String { String(format: "%d:%02d", startMinutes / 60, startMinutes % 60) }
    /// "17:00" style label for when auto-prime stops for the day.
    var endLabel: String {
        let m = (startMinutes + windowHours * 60) % (24 * 60)
        return String(format: "%d:%02d", m / 60, m % 60)
    }
}

enum CCLogin {
    static func newConfigDir(for id: UUID) -> String {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ClaudeUsage/cc/\(id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.path
    }

    /// Snapshot the CURRENT live login (macOS Keychain) into this account's own
    /// config-dir file, WITHOUT logging in again. Runs in Terminal so its
    /// Keychain read uses Terminal's own persistent "Always Allow". Resets the
    /// dir to a clean file-only state so `claude` reads the file, not the Keychain.
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
