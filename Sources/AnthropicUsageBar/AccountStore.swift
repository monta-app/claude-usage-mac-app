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
    @Published var priming: Set<UUID> = []   // accounts currently starting a session

    private let key = "configAccounts.v2"
    private var timer: Timer?
    private var scheduleTimer: Timer?
    private var lastPrimed: [UUID: Date] = [:]

    init() {
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        // Check auto-prime schedules once a minute (cheap; only acts on gaps).
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSchedules() }
        }
        Task { await refresh(); checkSchedules() }
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

    func setSchedule(_ account: ConfigAccount, _ schedule: PrimeSchedule) {
        guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[i].schedule = schedule
        persist()
        checkSchedules()
    }

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

    /// Kick off the 5h rolling window for this account now (one tiny message),
    /// then refresh so the new reset time / countdown shows immediately.
    func startSession(_ account: ConfigAccount) {
        guard !priming.contains(account.id) else { return }
        priming.insert(account.id)
        Task {
            await CredentialFile.refreshIfNeeded(account.configDir)
            _ = await ClaudeCode.primeSession(configDir: account.configDir)
            priming.remove(account.id)
            await refresh()
        }
    }

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

    // MARK: Auto-prime scheduling

    /// The 5h "current session" window for an account, if present.
    func sessionWindow(of id: UUID) -> ClaudeCode.Window? {
        guard case .ok(let ws)? = states[id] else { return nil }
        return ws.first { $0.id == "five_hour" || $0.label.lowercased().contains("session") }
    }

    /// True if a 5h block is currently running (has a future reset, or shows usage).
    private func sessionActive(_ id: UUID, now: Date) -> Bool {
        guard let w = sessionWindow(of: id) else { return false }
        if let r = w.resetAt, r > now { return true }
        return w.fraction > 0.02   // used but no parsed reset → still treat as active
    }

    /// Called every minute: within each enabled account's active window, if no
    /// 5h block is running and we didn't just prime, start one.
    func checkSchedules() {
        let now = Date()
        let cal = Calendar.current
        for a in accounts {
            guard let s = a.schedule, s.enabled, hasCredential(a) else { continue }
            if priming.contains(a.id) { continue }
            if s.weekdaysOnly {
                let wd = cal.component(.weekday, from: now)   // 1=Sun … 7=Sat
                if wd == 1 || wd == 7 { continue }
            }
            let dayStart = cal.startOfDay(for: now)
            let activeStart = dayStart.addingTimeInterval(Double(s.startMinutes) * 60)
            let activeEnd = activeStart.addingTimeInterval(Double(s.windowHours) * 3600)
            guard now >= activeStart, now <= activeEnd else { continue }
            if sessionActive(a.id, now: now) { continue }
            if let last = lastPrimed[a.id], now.timeIntervalSince(last) < 300 { continue }
            lastPrimed[a.id] = now
            startSession(a)
        }
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
