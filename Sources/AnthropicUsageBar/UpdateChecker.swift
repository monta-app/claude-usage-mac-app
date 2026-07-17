import Foundation
import AppKit
import AnthropicUsageCore

/// Checks GitHub Releases for a newer app build than the one running. The
/// "latest" release is rolling (rebuilt on every push to main), so we compare
/// the baked-in git SHA against the release's `target_commitish`. When a newer
/// build is found, posts a sticky alert (same osascript delivery the Notifier
/// uses) with a "Download" button that opens the DMG URL in the browser.
///
/// Runs on launch and every 12h; also triggered manually from the menu.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published var isChecking = false
    @Published var lastKnownRemoteSHA: String?

    private let lastSeenKey = "updateChecker.lastSeenSHA"
    private var timer: Timer?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 12 * 3600, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.check() }
        }
    }

    /// On-demand check (menu item).
    func checkNow() {
        Task { await check(manual: true) }
    }

    /// Background check. `manual` true means the user clicked "Check for
    /// Updates…", so always show a result (including "up to date"); silent
    /// background checks only surface when there's actually a newer build.
    func check(manual: Bool = false) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let apiURL = URL(string: "https://api.github.com/repos/\(AppVersion.repo)/releases/latest")!
        var req = URLRequest(url: apiURL)
        req.setValue("claude-usage/\(AppVersion.sha)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            if manual { alert(title: "Claude Usage update check",
                              body: "Couldn't reach GitHub to check for updates. Try again later.") }
            return
        }

        let remoteSHA = String((root["target_commitish"] as? String ?? "").prefix(7))
        lastKnownRemoteSHA = remoteSHA

        guard !remoteSHA.isEmpty, remoteSHA != AppVersion.sha else {
            if manual { alert(title: "Claude Usage is up to date",
                              body: "You're on \(AppVersion.sha), which is the latest build.") }
            return
        }

        // Only alert once per new SHA (don't spam every 12h for the same build).
        let alreadySeen = UserDefaults.standard.string(forKey: lastSeenKey)
        guard alreadySeen != remoteSHA else {
            if manual { alert(title: "Claude Usage update available",
                              body: "Build \(remoteSHA) is available (you're on \(AppVersion.sha)).\n\nDownload from:\nhttps://github.com/\(AppVersion.repo)/releases/latest") }
            return
        }
        UserDefaults.standard.set(remoteSHA, forKey: lastSeenKey)

        let dmgURL = "https://github.com/\(AppVersion.repo)/releases/latest/download/Claude-Usage.dmg"
        alert(title: "Claude Usage update available",
              body: "Build \(remoteSHA) is available (you're on \(AppVersion.sha)).\n\nClick OK to open the DMG in your browser, then drag Claude Usage to Applications to update.")
        // The osascript alert is fire-and-forget; we can't capture the button
        // click. So also open the DMG URL proactively — a browser tab the user
        // can act on now or later. Harmless if they dismiss.
        NSWorkspace.shared.open(URL(string: dmgURL)!)
    }

    // MARK: Delivery (mirrors Notifier's osascript approach — no entitlements
    // needed, works for ad-hoc signed apps)

    private func alert(title: String, body: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", Self.appleScript(title: title, body: body)]
        try? task.run()
    }

    private static func appleScript(title: String, body: String) -> String {
        "activate\ndisplay alert \(quote(title)) message \(quote(body)) as informational buttons {\"OK\"} default button \"OK\""
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
