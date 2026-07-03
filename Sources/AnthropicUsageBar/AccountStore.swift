import Foundation
import SwiftUI

/// Shows plan usage for multiple Claude accounts at once. Each account is an
/// independent Claude Code login living in its own config dir (the default
/// account uses ~/.claude). The app only runs `claude` as a subprocess — it
/// never touches the Keychain or modifies any login.
@MainActor
final class AccountStore: ObservableObject {
    /// Default account (index 0) + extras. Always contains the default.
    @Published var accounts: [ConfigAccount] = []
    @Published var states: [UUID: ClaudeCode.State] = [:]
    @Published var identities: [UUID: ClaudeCode.Identity] = [:]
    @Published var lastUpdated: Date?
    @Published var isRefreshing = false

    private let key = "configAccounts.v1"
    private var timer: Timer?

    /// Stable id for the default (~/.claude) account.
    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-0000000000DE")!

    init() {
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        Task { await refresh() }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([ConfigAccount].self, from: data) {
            accounts = decoded
        }
        if !accounts.contains(where: { $0.id == Self.defaultID }) {
            accounts.insert(ConfigAccount(id: Self.defaultID, name: "Default", configDir: nil), at: 0)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: Account management (no Keychain, no login mutation)

    func addAccount(name: String) {
        let id = UUID()
        let dir = CCLogin.newConfigDir(for: id)
        accounts.append(ConfigAccount(id: id, name: name.isEmpty ? "Account \(accounts.count + 1)" : name, configDir: dir))
        persist()
    }

    func rename(_ account: ConfigAccount, to name: String) {
        let t = name.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[i].name = t
        persist()
    }

    func login(_ account: ConfigAccount) { CCLogin.openLogin(configDir: account.configDir) }

    func remove(_ account: ConfigAccount) {
        guard account.id != Self.defaultID else { return }   // can't remove default
        if let dir = account.configDir { try? FileManager.default.removeItem(atPath: dir) }
        accounts.removeAll { $0.id == account.id }
        states[account.id] = nil; identities[account.id] = nil
        persist()
    }

    // MARK: Refresh (read-only)

    func refresh() async {
        isRefreshing = true
        let items = accounts
        await withTaskGroup(of: (UUID, ClaudeCode.State, ClaudeCode.Identity?).self) { group in
            for a in items {
                group.addTask {
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

    /// Title for a card: the real org from the CLI, else the user's name.
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
        if !parts.isEmpty {
            let s = parts.joined(separator: " · ")
            return maxed ? "⚠︎ \(s)" : s
        }
        if case .loading? = states[Self.defaultID] { return "…" }
        if states[Self.defaultID] == nil { return "…" }
        return "Claude"
    }
}
