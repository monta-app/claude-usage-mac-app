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
        let indexExists = FileManager.default.fileExists(atPath: indexURL.path)

        // Import the index from UserDefaults if the new JSON index doesn't
        // exist yet (first run of the new app on this machine). The imported
        // configDirs still point at the old Library/Application Support path;
        // migrateLegacyConfigDirs() (called below + in AccountsManager.init)
        // relocates the credential dirs and repoints them.
        if !indexExists {
            if let data = UserDefaults.standard.data(forKey: Self.legacyKey),
               let decoded = try? JSONDecoder().decode([ConfigAccount].self, from: data),
               !decoded.isEmpty {
                manager.replaceAll(decoded)
                manager.migrateLegacyConfigDirs()
                return
            }
            // v1 had an optional configDir (only file-based accounts were kept).
            if let data = UserDefaults.standard.data(forKey: Self.legacyKeyV1),
               let old = try? JSONDecoder().decode([LegacyAccount].self, from: data) {
                let mapped = old.compactMap { l in
                    l.configDir.map { ConfigAccount(id: l.id, name: l.name, configDir: $0) }
                }
                if !mapped.isEmpty {
                    manager.replaceAll(mapped)
                    manager.migrateLegacyConfigDirs()
                }
            }
        } else {
            // Index already exists (e.g. created by PR#1's partial migration,
            // which moved the index but not the credential dirs). Make sure any
            // accounts still pointing at the old path are relocated.
            manager.migrateLegacyConfigDirs()
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
        for (id, r) in results {
            states[id] = r.state
            if let ident = r.identity { identities[id] = ident }
        }
        lastUpdated = Date()
        isRefreshing = false
        Notifier.shared.evaluate(accounts: accounts, states: states) { self.title(for: $0) }
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
        if !parts.isEmpty { return (maxed ? "⚠︎ " : "") + parts.joined(separator: " · ") }
        if accounts.isEmpty { return "Claude" }
        return "…"
    }
}
