import Foundation
import SwiftUI

@MainActor
final class AccountStore: ObservableObject {
    /// Primary Claude Code login (default ~/.claude config dir).
    @Published var claudeCode: ClaudeCode.State = .loading
    /// Additional Claude Code logins, each in its own config dir.
    @Published var ccAccounts: [CCAccount] = []
    @Published var ccStates: [UUID: ClaudeCode.State] = [:]
    /// The real logged-in account (email / org) per account, from the CLI.
    @Published var identities: [UUID: ClaudeCode.Identity] = [:]
    @Published var lastUpdated: Date?
    @Published var isRefreshing = false

    /// Fixed id for the Primary account's optional token.
    static let primaryTokenID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private let ccKey = "ccAccounts.v2"
    private var ccTimer: Timer?

    init() {
        load()
        // Plan limits every 5 min (token accounts hit a rate-limited endpoint).
        ccTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { await self?.refreshClaudeCode() }
        }
        Task { await refreshAll() }
    }

    // MARK: Persistence

    private func load() {
        if let data = UserDefaults.standard.data(forKey: ccKey),
           let decoded = try? JSONDecoder().decode([CCAccount].self, from: data) {
            ccAccounts = decoded
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(ccAccounts) {
            UserDefaults.standard.set(data, forKey: ccKey)
        }
    }

    // MARK: Accounts

    func loginPrimary() { CCLogin.openLogin(configDir: nil) }

    func addCCAccount() {
        let id = UUID()
        let dir = CCLogin.newConfigDir(for: id)
        ccAccounts.append(CCAccount(id: id, configDir: dir))
        persist()
    }

    func removeCCAccount(_ account: CCAccount) {
        ccAccounts.removeAll { $0.id == account.id }
        ccStates[account.id] = nil; identities[account.id] = nil
        ccTokenCache[account.id] = nil
        try? FileManager.default.removeItem(atPath: account.configDir)
        persist()
    }

    // MARK: Long-lived tokens

    private var ccTokenCache: [UUID: String] = [:]
    func ccToken(for id: UUID) -> String? {
        if let c = ccTokenCache[id] { return c }
        guard let t = Keychain.load(for: id, service: Keychain.ccService) else { return nil }
        ccTokenCache[id] = t
        return t
    }
    func hasToken(for id: UUID) -> Bool { ccToken(for: id) != nil }
    func setCCToken(_ token: String, for id: UUID) {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        Keychain.save(key: t, for: id, service: Keychain.ccService)
        ccTokenCache[id] = t
        Task { await refreshClaudeCode() }
    }
    func clearCCToken(for id: UUID) {
        Keychain.delete(for: id, service: Keychain.ccService)
        ccTokenCache[id] = nil
        Task { await refreshClaudeCode() }
    }

    // MARK: Refresh

    func refreshAll() async {
        isRefreshing = true
        await refreshClaudeCode()
        lastUpdated = Date()
        isRefreshing = false
    }

    func refreshClaudeCode() async {
        let primaryToken = ccToken(for: Self.primaryTokenID)
        async let primary: ClaudeCode.State = {
            if let t = primaryToken { return await ClaudeCode.fetchViaToken(t) }
            return await ClaudeCode.fetchUsage(configDir: nil)
        }()
        let extras: [(UUID, String?, String)] = ccAccounts.map { ($0.id, ccToken(for: $0.id), $0.configDir) }
        await withTaskGroup(of: (UUID, ClaudeCode.State).self) { group in
            for (id, token, dir) in extras {
                group.addTask {
                    if let token { return (id, await ClaudeCode.fetchViaToken(token)) }
                    return (id, await ClaudeCode.fetchUsage(configDir: dir))
                }
            }
            for await (id, state) in group { ccStates[id] = merge(new: state, old: ccStates[id]) }
        }
        claudeCode = merge(new: await primary, old: claudeCode)
        await refreshIdentities()
    }

    /// Resolve each account's real logged-in email/org via `claude auth status`.
    func refreshIdentities() async {
        let items: [(UUID, String?, String?)] =
            [(Self.primaryTokenID, ccToken(for: Self.primaryTokenID), nil)] +
            ccAccounts.map { ($0.id, ccToken(for: $0.id), $0.configDir) }
        await withTaskGroup(of: (UUID, ClaudeCode.Identity?).self) { group in
            for (id, token, dir) in items {
                group.addTask { (id, await ClaudeCode.fetchIdentity(configDir: dir, token: token)) }
            }
            for await (id, ident) in group {
                if let ident { identities[id] = ident }
            }
        }
    }

    private func merge(new: ClaudeCode.State, old: ClaudeCode.State?) -> ClaudeCode.State {
        if case .rateLimited = new, let old, case .ok = old { return old }
        return new
    }

    // MARK: Derived

    func peak(of state: ClaudeCode.State) -> Double? {
        if case .ok(let w) = state { return w.map(\.fraction).max() }
        return nil
    }

    /// Card title: the org name from the CLI, else a sensible fallback.
    func title(for id: UUID) -> String {
        if let org = identities[id]?.orgName, !org.isEmpty { return org }
        if id == Self.primaryTokenID { return "Primary" }
        return "New plan"
    }

    var menuBarTitle: String {
        var parts: [String] = []
        var anyMaxed = false
        for state in [claudeCode] + ccAccounts.map({ ccStates[$0.id] ?? .loading }) {
            if let p = peak(of: state) {
                if p >= 1 { anyMaxed = true }
                parts.append("\(Int((p * 100).rounded()))%")
            }
        }
        if !parts.isEmpty {
            let joined = parts.joined(separator: " · ")
            return anyMaxed ? "⚠︎ \(joined)" : joined
        }
        if case .loading = claudeCode { return "…" }
        return "Claude"
    }
}
