import Foundation
import SwiftUI

@MainActor
final class AccountStore: ObservableObject {
    /// Registered accounts (login snapshots live in the Keychain).
    @Published var accounts: [SwitchAccount] = []
    /// Which account's login is currently active (in the live Claude Code slot).
    @Published var activeID: UUID?
    /// Plan usage of the currently-active login.
    @Published var claudeCode: ClaudeCode.State = .loading
    /// Live identity of the active login (org / email).
    @Published var activeIdentity: ClaudeCode.Identity?
    @Published var lastUpdated: Date?
    @Published var isRefreshing = false
    @Published var status: String?   // transient user-facing message

    private let accountsKey = "switchAccounts.v1"
    private let activeKey = "activeAccountID.v1"
    private var timer: Timer?

    init() {
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        Task { await refresh() }
    }

    // MARK: Persistence

    private func load() {
        if let data = UserDefaults.standard.data(forKey: accountsKey),
           let decoded = try? JSONDecoder().decode([SwitchAccount].self, from: data) {
            accounts = decoded
        }
        if let s = UserDefaults.standard.string(forKey: activeKey) { activeID = UUID(uuidString: s) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: accountsKey)
        }
        UserDefaults.standard.set(activeID?.uuidString, forKey: activeKey)
    }

    // MARK: Registering & swapping accounts

    /// Snapshot the current live login as a new registered account.
    func addCurrentLogin() async {
        guard let (_, data) = ClaudeCredential.read() else {
            status = "Couldn't read the current Claude Code login. Log in first."
            return
        }
        guard ClaudeCredential.isValid(data) else {
            status = "The current login isn't a subscription login."
            return
        }
        // Label from the live identity.
        let ident = await ClaudeCode.fetchIdentity(configDir: nil, token: nil)
        let label = [ident?.orgName, ident?.email].compactMap { $0 }
            .filter { !$0.isEmpty }.joined(separator: " · ").nilIfEmpty ?? "Account \(accounts.count + 1)"

        // If this identity is already registered, update its snapshot instead of duplicating.
        let acct: SwitchAccount
        if let existing = accounts.first(where: { $0.label == label }) {
            acct = existing
        } else {
            acct = SwitchAccount(label: label)
            accounts.append(acct)
        }
        Keychain.save(key: String(data: data, encoding: .utf8) ?? "", for: acct.id)
        activeID = acct.id
        persist()
        status = "Added \(label)."
        await refresh()
    }

    /// Swap the live login to `account`'s saved snapshot. Re-snapshots the
    /// currently-active account first so its latest (refreshed) token is kept.
    func swap(to account: SwitchAccount) async {
        // 1. Preserve the active account's current credential.
        if let activeID, activeID != account.id,
           let (_, data) = ClaudeCredential.read(), ClaudeCredential.isValid(data) {
            Keychain.save(key: String(data: data, encoding: .utf8) ?? "", for: activeID)
        }
        // 2. Restore the target's snapshot into the live login slot.
        guard let snap = Keychain.load(for: account.id),
              let data = snap.data(using: .utf8), ClaudeCredential.isValid(data) else {
            status = "No saved login for \(account.label) — re-add it."
            return
        }
        guard ClaudeCredential.write(data) else {
            status = "Couldn't write the login (Keychain permission?). Try again and Always Allow."
            return
        }
        activeID = account.id
        persist()
        status = "Switched to \(account.label)."
        await refresh()
    }

    func remove(_ account: SwitchAccount) {
        Keychain.delete(for: account.id)
        accounts.removeAll { $0.id == account.id }
        if activeID == account.id { activeID = nil }
        persist()
    }

    func openLogin() { CCLogin.openLogin() }

    // MARK: Refresh (active login only)

    func refresh() async {
        isRefreshing = true
        async let usage = ClaudeCode.fetchUsage(configDir: nil)
        async let ident = ClaudeCode.fetchIdentity(configDir: nil, token: nil)
        claudeCode = await usage
        activeIdentity = await ident
        reconcileActive()
        lastUpdated = Date()
        isRefreshing = false
    }

    /// If the live login's identity matches a registered account, mark it active
    /// (covers logins changed outside the app, e.g. via `claude /login`).
    private func reconcileActive() {
        guard let ident = activeIdentity else { return }
        let label = [ident.orgName, ident.email].compactMap { $0 }
            .filter { !$0.isEmpty }.joined(separator: " · ")
        if let match = accounts.first(where: { $0.label == label }) {
            if activeID != match.id { activeID = match.id; persist() }
        }
    }

    // MARK: Derived

    func peak(of state: ClaudeCode.State) -> Double? {
        if case .ok(let w) = state { return w.map(\.fraction).max() }
        return nil
    }

    var activeLabel: String {
        if let id = activeID, let a = accounts.first(where: { $0.id == id }) { return a.label }
        let ident = activeIdentity
        return [ident?.orgName, ident?.email].compactMap { $0 }
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
