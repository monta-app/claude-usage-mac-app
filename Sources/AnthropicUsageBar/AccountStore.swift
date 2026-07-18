import Foundation
import SwiftUI
import AnthropicUsageCore

/// SwiftUI `ObservableObject` wrapper around `AccountsManager`. Owns the
/// refresh + auto-prime timers and the published state the menu-bar UI binds
/// to. All persistence and account logic is delegated to `AccountsManager`
/// (in AnthropicUsageCore) so the `ccu` CLI can reuse it verbatim.
@MainActor
final class AccountStore: ObservableObject {
    @Published var accounts: [ConfigAccount] = []
    @Published var states: [UUID: ClaudeCode.State] = [:]
    @Published var identities: [UUID: ClaudeCode.Identity] = [:]
    @Published var lastUpdated: Date?
    @Published var isRefreshing = false
    @Published var priming: Set<UUID> = []   // accounts currently starting a session
    /// The account Claude Code is currently logged into (matched from the
    /// default `~/.claude` login's identity). nil = couldn't match / not one
    /// of the tracked accounts.
    @Published var activeAccountID: UUID?
    /// Accounts whose displayed `.ok` reading is stale — a later refresh hit a
    /// transient failure (429 / network) so we're showing the last good data.
    @Published var staleAccounts: Set<UUID> = []
    /// When each account's currently-displayed usage was actually fetched.
    /// Preserved through stale periods so the UI can show "as of <time>".
    @Published var capturedAt: [UUID: Date] = [:]

    private let manager: AccountsManager
    private var timer: Timer?
    private var scheduleTimer: Timer?

    // Legacy UserDefaults index used by the pre-Core GUI. Used once, to adopt
    // existing installs' accounts into the new shared JSON index at
    // ~/.claude-usage/accounts.json. Stored configDir paths are absolute, so
    // old accounts keep working where they are; only NEW accounts go to
    // ~/.claude-usage/cc/<uuid>.
    private static let legacyKey = "configAccounts.v2"
    private static let legacyKeyV1 = "configAccounts.v1"

    init() {
        manager = AccountsManager(baseDir: AccountsManager.defaultBaseDir())
        migrateFromUserDefaultsIfNeeded()
        accounts = manager.accounts
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.refresh() }
        }
        // Check auto-prime schedules once a minute (cheap; only acts on gaps).
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.checkSchedules() }
        }
        Task { await refresh(); checkSchedules() }
    }

    // MARK: One-time migration from the pre-Core UserDefaults index

    private struct LegacyAccount: Codable { var id: UUID; var name: String; var configDir: String? }

    private func migrateFromUserDefaultsIfNeeded() {
        let indexURL = manager.baseDir.appendingPathComponent("accounts.json")
        guard !FileManager.default.fileExists(atPath: indexURL.path) else { return }

        if let data = UserDefaults.standard.data(forKey: Self.legacyKey),
           let decoded = try? JSONDecoder().decode([ConfigAccount].self, from: data),
           !decoded.isEmpty {
            manager.replaceAll(decoded)
            return
        }
        // v1 had an optional configDir (only file-based accounts were kept).
        if let data = UserDefaults.standard.data(forKey: Self.legacyKeyV1),
           let old = try? JSONDecoder().decode([LegacyAccount].self, from: data) {
            let mapped = old.compactMap { l in
                l.configDir.map { ConfigAccount(id: l.id, name: l.name, configDir: $0) }
            }
            if !mapped.isEmpty { manager.replaceAll(mapped) }
        }
    }

    // MARK: Accounts

    /// Add a new account by capturing whatever you're logged into right now.
    func addCurrentLogin() {
        let name = "Account \(accounts.count + 1)"
        let acct = manager.add(name: name)
        accounts = manager.accounts
        CCLogin.captureCurrent(configDir: acct.configDir)   // Terminal captures the live login into this dir
    }

    /// Re-capture the current live login into an existing account (if it went stale).
    func recapture(_ account: ConfigAccount) { CCLogin.captureCurrent(configDir: account.configDir) }

    func setSchedule(_ account: ConfigAccount, _ schedule: PrimeSchedule) {
        manager.setSchedule(account, schedule)
        accounts = manager.accounts
        checkSchedules()
    }

    func rename(_ account: ConfigAccount, to name: String) {
        manager.rename(account, to: name)
        accounts = manager.accounts
    }

    func remove(_ account: ConfigAccount) {
        manager.remove(account)
        accounts = manager.accounts
        states[account.id] = nil; identities[account.id] = nil
    }

    func hasCredential(_ account: ConfigAccount) -> Bool { manager.hasCredential(account) }

    /// Kick off the 5h rolling window for this account now (one tiny message),
    /// then refresh so the new reset time / countdown shows immediately.
    func startSession(_ account: ConfigAccount) {
        guard !priming.contains(account.id) else { return }
        priming.insert(account.id)
        Task {
            await manager.startSession(account)
            priming.remove(account.id)
            await refresh()
        }
    }

    // MARK: Refresh (read-only + token refresh; no Keychain)

    func refresh() async {
        isRefreshing = true
        let results = await manager.refreshAll()
        let now = Date()
        for (id, r) in results {
            if let ident = r.identity { identities[id] = ident }
            // A transient failure (throttle / network error) after we already
            // had good numbers shouldn't blank the account — keep showing the
            // last good reading, mark it stale, and keep its capture time so the
            // UI can say how old it is. Real state changes (logged out, expired,
            // CLI gone) DO replace it — those aren't stale data, they're news.
            if isTransientFailure(r.state), case .ok = states[id] {
                staleAccounts.insert(id)
            } else {
                states[id] = r.state
                staleAccounts.remove(id)
                if hasUsableData(r.state) { capturedAt[id] = now }
            }
        }
        // Which tracked account is Claude Code currently logged into? Match the
        // default (~/.claude) login's identity to a tracked account. Email alone
        // is NOT unique (several orgs can share one email), so match on the
        // (email, org) pair — falling back to a unique email match only when the
        // active login carries no org.
        activeAccountID = await ClaudeCode.fetchIdentity(configDir: nil, token: nil).flatMap { active in
            func eq(_ a: String?, _ b: String?) -> Bool {
                guard let a, let b else { return a == nil && b == nil }
                return a.caseInsensitiveCompare(b) == .orderedSame
            }
            let full = accounts.first {
                eq(identities[$0.id]?.email, active.email) && eq(identities[$0.id]?.orgName, active.orgName)
            }
            if let full { return full.id }
            guard active.orgName == nil, let email = active.email else { return nil }
            let byEmail = accounts.filter { eq(identities[$0.id]?.email, email) }
            return byEmail.count == 1 ? byEmail[0].id : nil
        }
        lastUpdated = Date()
        isRefreshing = false
        Notifier.shared.evaluate(accounts: accounts, states: states) { self.title(for: $0) }
        Notifier.shared.evaluateMove(recommendation, accounts: accounts) { self.title(for: $0) }
    }

    /// A throttle or transient network error — not a real change in the account,
    /// just a failed poll. Worth riding out on the last good reading.
    private func isTransientFailure(_ s: ClaudeCode.State) -> Bool {
        switch s {
        case .rateLimited, .error: return true
        default: return false
        }
    }

    /// Does this state carry real usage we'd want to timestamp and keep?
    private func hasUsableData(_ s: ClaudeCode.State) -> Bool {
        switch s {
        case .ok, .stats: return true
        default: return false
        }
    }

    // MARK: Recommendation ("what should I move to?")

    /// The current move advice, or nil when the seat you're on is fine (or we
    /// can't tell which seat you're on). Recomputed from live state on demand.
    var recommendation: Recommender.Move? {
        var usages: [UUID: Recommender.Usage] = [:]
        for a in accounts {
            if case .ok(let windows)? = states[a.id] {
                usages[a.id] = Recommender.usage(from: windows)
            }
        }
        return Recommender.recommend(usages: usages, activeID: activeAccountID)
    }

    // MARK: Auto-prime scheduling

    /// Called every minute: within each enabled account's active window, if no
    /// 5h block is running and we didn't just prime, start one.
    func checkSchedules() {
        Task {
            _ = await manager.checkSchedules(states: states)
            // Schedules may have started a session; refresh so it shows up.
            await refresh()
        }
    }

    // MARK: Derived

    func peak(of id: UUID) -> Double? { manager.peak(of: id, states: states) }

    func title(for account: ConfigAccount) -> String { manager.title(for: account, identities: identities) }

    var menuBarTitle: String {
        var parts: [String] = []
        var maxed = false
        for a in accounts {
            if let p = peak(of: a.id) {
                if p >= 1 { maxed = true }
                parts.append("\(Int((p * 100).rounded()))%")
            }
        }
        var text: String
        if !parts.isEmpty { text = (maxed ? "⚠︎ " : "") + parts.joined(separator: " · ") }
        else if accounts.isEmpty { return "Claude" }
        else { return fallbackTitle }

        // Append a compact "move to" hint so the suggestion is visible without
        // opening the menu. Arrow style signals urgency: ⇥ = must move, → = nudge.
        if let move = recommendation,
           let target = accounts.first(where: { $0.id == move.targetID }) {
            let arrow = move.urgency == .mustMove ? "⇥" : "→"
            text += "  \(arrow) \(title(for: target))"
        }
        return text
    }

    /// What to show in the menu bar when no account has usable usage numbers.
    /// Rather than a bare "…" (which reads as "still loading" forever), reflect
    /// the dominant reason so a glance tells you *why* there's no number:
    /// throttled, logged out, expired, or genuinely still loading.
    private var fallbackTitle: String {
        // Still fetching for the first time → the honest "working on it".
        if isRefreshing && states.values.allSatisfy({ if case .loading = $0 { return true } else { return false } }) {
            return "…"
        }
        var throttled = false, expired = false, loggedOut = false, loading = false
        for a in accounts {
            switch states[a.id] {
            case .rateLimited: throttled = true
            case .expired:     expired = true
            case .notLoggedIn: loggedOut = true
            case .loading, nil: loading = true
            default: break
            }
        }
        // Order by how actionable the state is for the user.
        if throttled { return "◴ limited" }    // transient — will retry on its own
        if expired   { return "⚠︎ log in" }    // needs re-auth
        if loggedOut { return "log in" }
        if loading   { return "…" }
        return "—"                              // stats-only / errors: nothing to show
    }
}
