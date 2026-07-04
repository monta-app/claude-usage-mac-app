import Foundation
import SwiftUI

/// Shows plan usage for multiple Claude accounts at once. Every account is
/// file-based (its own `.credentials.json`), captured from a live login and
/// refreshed by the app. The app never touches the macOS Keychain — so nothing
/// mirrors, and switching Conductor/Claude Code doesn't change what's shown.
@MainActor
final class AccountStore: ObservableObject {
    @Published var accounts: [ConfigAccount] = []
    @Published var states: [UUID: ClaudeCode.State] = [:]
    @Published var identities: [UUID: ClaudeCode.Identity] = [:]
    @Published var lastUpdated: Date?
    @Published var isRefreshing = false

    private let key = "configAccounts.v2"
    private var timer: Timer?

    init() {
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        Task { await refresh() }
    }

    // MARK: Persistence (with migration from v1 default+extra model)

    private struct Legacy: Codable { var id: UUID; var name: String; var configDir: String? }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([ConfigAccount].self, from: data) {
            accounts = decoded
            return
        }
        // Migrate v1: keep only file-based (configDir != nil) accounts.
        if let data = UserDefaults.standard.data(forKey: "configAccounts.v1"),
           let old = try? JSONDecoder().decode([Legacy].self, from: data) {
            accounts = old.compactMap { l in
                l.configDir.map { ConfigAccount(id: l.id, name: l.name, configDir: $0) }
            }
            persist()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: Accounts

    /// Add a new account by capturing whatever you're logged into right now.
    func addCurrentLogin() {
        let id = UUID()
        let dir = CCLogin.newConfigDir(for: id)
        accounts.append(ConfigAccount(id: id, name: "Account \(accounts.count + 1)", configDir: dir))
        persist()
        CCLogin.captureCurrent(configDir: dir)   // Terminal captures the live login into this dir
    }

    /// Re-capture the current live login into an existing account (if it went stale).
    func recapture(_ account: ConfigAccount) { CCLogin.captureCurrent(configDir: account.configDir) }

    func rename(_ account: ConfigAccount, to name: String) {
        let t = name.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[i].name = t
        persist()
    }

    func remove(_ account: ConfigAccount) {
        try? FileManager.default.removeItem(atPath: account.configDir)
        accounts.removeAll { $0.id == account.id }
        states[account.id] = nil; identities[account.id] = nil
        persist()
    }

    func hasCredential(_ account: ConfigAccount) -> Bool { CredentialFile.exists(account.configDir) }

    // MARK: Refresh (read-only + token refresh; no Keychain)

    func refresh() async {
        isRefreshing = true
        let items = accounts
        await withTaskGroup(of: (UUID, ClaudeCode.State, ClaudeCode.Identity?).self) { group in
            for a in items {
                group.addTask {
                    await CredentialFile.refreshIfNeeded(a.configDir)   // keep token alive
                    async let u = ClaudeCode.fetchUsage(configDir: a.configDir)
                    async let i = ClaudeCode.fetchIdentity(configDir: a.configDir, token: nil)
                    return (a.id, await u, await i)
                }
            }
            for await (id, state, ident) in group {
                states[id] = state
                if let ident { identities[id] = ident }
            }
        }
        lastUpdated = Date()
        isRefreshing = false
    }

    // MARK: Derived

    func peak(of id: UUID) -> Double? {
        if case .ok(let w)? = states[id] { return w.map(\.fraction).max() }
        return nil
    }

    func title(for account: ConfigAccount) -> String {
        if let org = identities[account.id]?.orgName, !org.isEmpty { return org }
        return account.name
    }

    var menuBarTitle: String {
        var parts: [String] = []
        var maxed = false
        for a in accounts {
            if let p = peak(of: a.id) {
                if p >= 1 { maxed = true }
                parts.append("\(Int((p * 100).rounded()))%")
            }
        }
        if !parts.isEmpty { return (maxed ? "⚠︎ " : "") + parts.joined(separator: " · ") }
        if accounts.isEmpty { return "Claude" }
        return "…"
    }
}
