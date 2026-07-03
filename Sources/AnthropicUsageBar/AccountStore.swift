import Foundation
import SwiftUI

@MainActor
final class AccountStore: ObservableObject {
    /// Primary Claude Code login (default ~/.claude config dir).
    @Published var claudeCode: ClaudeCode.State = .loading
    /// Display name for the Primary login (renameable).
    @Published var primaryName: String = "Primary"
    /// Additional Claude Code logins, each in its own config dir.
    @Published var ccAccounts: [CCAccount] = []
    @Published var ccStates: [UUID: ClaudeCode.State] = [:]
    /// Per-account per-member Claude Code spend (month-to-date, USD).
    @Published var spend: [UUID: ClaudeCodeSpend.Result] = [:]
    /// Member email per account (Primary keyed by primaryTokenID).
    @Published var memberEmails: [UUID: String] = [:]
    @Published var lastUpdated: Date?
    @Published var isRefreshing = false

    /// Fixed id for the Primary account's optional token / admin key / email.
    static let primaryTokenID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private let ccKey = "ccAccounts.v2"
    private var ccTimer: Timer?      // Claude Code plan limits
    private var spendTimer: Timer?   // Per-member Claude Code spend (slow)

    init() {
        load()
        // Plan limits every 5 min (token accounts hit a rate-limited endpoint).
        ccTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { await self?.refreshClaudeCode() }
        }
        // Per-member spend every 30 min (monthly figure; past days are cached).
        spendTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { await self?.refreshSpend() }
        }
        Task { await refreshAll() }
    }

    // MARK: Persistence

    private func load() {
        if let data = UserDefaults.standard.data(forKey: ccKey),
           let decoded = try? JSONDecoder().decode([CCAccount].self, from: data) {
            ccAccounts = decoded
        }
        if let n = UserDefaults.standard.string(forKey: "ccPrimaryName"), !n.isEmpty {
            primaryName = n
        }
        // Restore member emails: primary + per-account.
        if let e = UserDefaults.standard.string(forKey: "primaryEmail"), !e.isEmpty {
            memberEmails[Self.primaryTokenID] = e
        }
        for a in ccAccounts { if let e = a.memberEmail, !e.isEmpty { memberEmails[a.id] = e } }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(ccAccounts) {
            UserDefaults.standard.set(data, forKey: ccKey)
        }
        UserDefaults.standard.set(primaryName, forKey: "ccPrimaryName")
    }

    // MARK: Primary login

    func loginPrimary() { CCLogin.openLogin(configDir: nil) }

    func renamePrimary(to name: String) {
        let t = name.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        primaryName = t
        persist()
    }

    // MARK: Extra accounts

    func addCCAccount(name: String) {
        let id = UUID()
        let dir = CCLogin.newConfigDir(for: id)
        ccAccounts.append(CCAccount(id: id, name: name.isEmpty ? "Plan \(ccAccounts.count + 2)" : name, configDir: dir))
        persist()
    }

    func renameCCAccount(_ account: CCAccount, to name: String) {
        let t = name.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let idx = ccAccounts.firstIndex(where: { $0.id == account.id }) else { return }
        ccAccounts[idx].name = t
        persist()
    }

    func removeCCAccount(_ account: CCAccount) {
        ccAccounts.removeAll { $0.id == account.id }
        ccStates[account.id] = nil; spend[account.id] = nil
        ccTokenCache[account.id] = nil; adminKeyCache[account.id] = nil
        try? FileManager.default.removeItem(atPath: account.configDir)
        persist()
    }

    // MARK: Long-lived tokens (plan limits)

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

    // MARK: Admin key + email (per-member spend)

    private var adminKeyCache: [UUID: String] = [:]

    func adminKey(for id: UUID) -> String? {
        if let c = adminKeyCache[id] { return c }
        guard let k = Keychain.load(for: id, service: Keychain.adminService) else { return nil }
        adminKeyCache[id] = k
        return k
    }
    func hasAdminKey(for id: UUID) -> Bool { adminKey(for: id) != nil }
    func setAdminKey(_ key: String, for id: UUID) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        Keychain.save(key: k, for: id, service: Keychain.adminService)
        adminKeyCache[id] = k
        Task { await refreshSpend() }
    }
    func clearAdminKey(for id: UUID) {
        Keychain.delete(for: id, service: Keychain.adminService)
        adminKeyCache[id] = nil; spend[id] = nil
    }

    func email(for id: UUID) -> String { memberEmails[id] ?? "" }
    func setEmail(_ email: String, for id: UUID) {
        let e = email.trimmingCharacters(in: .whitespaces)
        memberEmails[id] = e
        if id == Self.primaryTokenID {
            UserDefaults.standard.set(e, forKey: "primaryEmail")
        } else if let idx = ccAccounts.firstIndex(where: { $0.id == id }) {
            ccAccounts[idx].memberEmail = e
            persist()
        }
        Task { await refreshSpend() }
    }

    // MARK: Refresh

    func refreshAll() async {
        isRefreshing = true
        async let cc: Void = refreshClaudeCode()
        async let sp: Void = refreshSpend()
        await cc; await sp
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
    }

    func refreshSpend() async {
        let ids = [Self.primaryTokenID] + ccAccounts.map(\.id)
        for id in ids {
            guard let key = adminKey(for: id), let email = memberEmails[id], !email.isEmpty else {
                spend[id] = .noConfig
                continue
            }
            if spend[id] == nil { spend[id] = .loading }
            spend[id] = await ClaudeCodeSpend.monthToDate(analyticsKey: key, email: email)
        }
    }

    /// A transient 429 shouldn't wipe good data — keep the last good reading.
    private func merge(new: ClaudeCode.State, old: ClaudeCode.State?) -> ClaudeCode.State {
        if case .rateLimited = new, let old, case .ok = old { return old }
        return new
    }

    // MARK: Derived

    func peak(of state: ClaudeCode.State) -> Double? {
        if case .ok(let w) = state { return w.map(\.fraction).max() }
        return nil
    }

    func spendUSD(for id: UUID) -> Double? {
        if case .amount(let v) = spend[id] { return v }
        return nil
    }

    var menuBarTitle: String {
        var parts: [String] = []
        var anyMaxed = false
        let ids = [Self.primaryTokenID] + ccAccounts.map(\.id)
        let states: [ClaudeCode.State] = [claudeCode] + ccAccounts.map { ccStates[$0.id] ?? .loading }
        for (i, state) in states.enumerated() {
            var piece = ""
            if let p = peak(of: state) {
                if p >= 1 { anyMaxed = true }
                piece = "\(Int((p * 100).rounded()))%"
            }
            if let s = spendUSD(for: ids[i]) {
                piece += piece.isEmpty ? String(format: "$%.0f", s) : String(format: " ($%.0f)", s)
            }
            if !piece.isEmpty { parts.append(piece) }
        }
        if !parts.isEmpty {
            let joined = parts.joined(separator: " · ")
            return anyMaxed ? "⚠︎ \(joined)" : joined
        }
        if case .loading = claudeCode { return "…" }
        return "Claude"
    }
}
