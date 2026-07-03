import Foundation
import SwiftUI

/// Shows the plan usage of the **currently active** Claude Code login.
/// The app never touches the Keychain — it only runs `claude` as a subprocess
/// (which reads its own login) and, to switch accounts, opens `claude /login`.
@MainActor
final class AccountStore: ObservableObject {
    @Published var claudeCode: ClaudeCode.State = .loading
    @Published var identity: ClaudeCode.Identity?
    @Published var lastUpdated: Date?
    @Published var isRefreshing = false

    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        Task { await refresh() }
    }

    func refresh() async {
        isRefreshing = true
        async let usage = ClaudeCode.fetchUsage(configDir: nil)
        async let ident = ClaudeCode.fetchIdentity(configDir: nil, token: nil)
        claudeCode = await usage
        identity = await ident
        lastUpdated = Date()
        isRefreshing = false
    }

    /// Switch the active account by re-running Claude Code's own login.
    func switchAccount() { CCLogin.openLogin() }

    func peak(of state: ClaudeCode.State) -> Double? {
        if case .ok(let w) = state { return w.map(\.fraction).max() }
        return nil
    }

    var activeLabel: String {
        [identity?.orgName, identity?.email].compactMap { $0 }
            .filter { !$0.isEmpty }.joined(separator: " · ").nilIfEmpty ?? "Claude Code"
    }

    var menuBarTitle: String {
        if let p = peak(of: claudeCode) {
            let pct = "\(Int((p * 100).rounded()))%"
            return p >= 1 ? "⚠︎ \(pct)" : pct
        }
        if case .loading = claudeCode { return "…" }
        return "Claude"
    }
}
