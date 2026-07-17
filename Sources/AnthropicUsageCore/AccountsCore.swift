import Foundation

/// A tracked account. Every account is **file-based**: its login lives in its
/// own `<configDir>/.credentials.json`, captured from a live login and kept
/// fresh by `CredentialFile`. Nothing reads the shared OS keychain, so
/// switching the active Claude Code / Conductor login never affects what the
/// app/CLI shows for tracked accounts.
public struct ConfigAccount: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var configDir: String
    /// Optional daily auto-prime schedule. nil / disabled = off.
    public var schedule: PrimeSchedule?

    public init(id: UUID = UUID(), name: String, configDir: String, schedule: PrimeSchedule? = nil) {
        self.id = id; self.name = name; self.configDir = configDir; self.schedule = schedule
    }
}

/// Auto-prime the 5h window on a daily schedule. The rule: within the active
/// window (`start` … `start + windowHours`), whenever no 5h block is running,
/// start one. This both kicks off the day at `start` AND restarts a fresh block
/// ASAP after the previous one runs out — while doing nothing when you're
/// already working (your own messages keep the block alive, so it only fills gaps).
public struct PrimeSchedule: Codable, Equatable, Sendable {
    public var enabled: Bool = false
    public var startMinutes: Int = 8 * 60   // minutes past local midnight
    public var windowHours: Int = 9         // keep chaining for this long after start
    public var weekdaysOnly: Bool = true

    public init(enabled: Bool = false,
                startMinutes: Int = 8 * 60,
                windowHours: Int = 9,
                weekdaysOnly: Bool = true) {
        self.enabled = enabled
        self.startMinutes = startMinutes
        self.windowHours = windowHours
        self.weekdaysOnly = weekdaysOnly
    }

    /// "8:00" style label for the start time.
    public var startLabel: String { String(format: "%d:%02d", startMinutes / 60, startMinutes % 60) }
    /// "17:00" style label for when auto-prime stops for the day.
    public var endLabel: String {
        let m = (startMinutes + windowHours * 60) % (24 * 60)
        return String(format: "%d:%02d", m / 60, m % 60)
    }
}

/// Result of a single account refresh. Sendable so it can cross actor
/// boundaries (GUI store is @MainActor; refresh runs off-main).
public struct RefreshResult: Sendable {
    public let state: ClaudeCode.State
    public let identity: ClaudeCode.Identity?
    public init(state: ClaudeCode.State, identity: ClaudeCode.Identity?) {
        self.state = state; self.identity = identity
    }
}

/// Owns the on-disk account index (`<baseDir>/accounts.json`) and per-account
/// login dirs (`<baseDir>/cc/<uuid>/.credentials.json`). Pure Foundation: no
/// AppKit, no SwiftUI, no keychain. Shared by the menu-bar app and the `ccu` CLI.
///
/// The GUI's `AccountStore` wraps this with `ObservableObject` + scheduled
/// refresh / auto-prime timers; the CLI drives it directly per invocation.
public final class AccountsManager {

    /// Default base dir: `~/.claude-usage/`. Used by both the GUI and the CLI so
    /// they share one account index and one set of login dirs.
    public static func defaultBaseDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-usage", isDirectory: true)
    }

    public private(set) var accounts: [ConfigAccount] = []
    public let baseDir: URL

    /// Per-account last-prime timestamps, used by `checkSchedules` to avoid
    /// re-priming the same account twice within 5 minutes. Owned by the
    /// manager so the GUI (@MainActor wrapper) and CLI don't fight over it.
    private var lastPrimed: [UUID: Date] = [:]

    public init(baseDir: URL = AccountsManager.defaultBaseDir()) {
        self.baseDir = baseDir
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: baseDir.appendingPathComponent("cc", isDirectory: true),
                                                 withIntermediateDirectories: true)
        load()
    }

    // MARK: Persistence

    private var indexURL: URL { baseDir.appendingPathComponent("accounts.json") }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([ConfigAccount].self, from: data)
        else { return }
        accounts = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// Replace the entire index (used for one-time migration from the GUI's
    /// legacy UserDefaults store). Persists immediately.
    public func replaceAll(_ newAccounts: [ConfigAccount]) {
        accounts = newAccounts
        persist()
    }

    // MARK: Accounts

    /// Create a new empty account slot (just the config dir). The caller is
    /// responsible for actually logging in (the GUI opens Terminal with
    /// `claude /login`; the CLI runs it inline under `CLAUDE_CONFIG_DIR`).
    @discardableResult
    public func add(name: String) -> ConfigAccount {
        let id = UUID()
        let dir = newConfigDir(for: id).path
        let acct = ConfigAccount(id: id, name: name, configDir: dir)
        accounts.append(acct)
        persist()
        return acct
    }

    public func newConfigDir(for id: UUID) -> URL {
        let dir = baseDir.appendingPathComponent("cc/\(id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public func remove(_ account: ConfigAccount) {
        try? FileManager.default.removeItem(atPath: account.configDir)
        accounts.removeAll { $0.id == account.id }
        persist()
    }

    public func rename(_ account: ConfigAccount, to name: String) {
        let t = name.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[i].name = t
        persist()
    }

    public func setSchedule(_ account: ConfigAccount, _ schedule: PrimeSchedule) {
        guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[i].schedule = schedule
        persist()
    }

    public func find(_ name: String) -> ConfigAccount? {
        let needle = name.lowercased()
        return accounts.first { $0.name.lowercased() == needle }
    }

    public func hasCredential(_ account: ConfigAccount) -> Bool {
        CredentialFile.exists(account.configDir)
    }

    // MARK: Refresh (read-only + token refresh)

    /// Refresh a single account: keep its token alive, then fetch current
    /// usage + identity. Returns the result; does not mutate the index.
    public func refresh(_ account: ConfigAccount) async -> RefreshResult {
        await Self.refreshOne(account)
    }

    /// Refresh every account in parallel.
    public func refreshAll() async -> [UUID: RefreshResult] {
        let items = accounts
        return await withTaskGroup(of: (UUID, RefreshResult).self) { group in
            for a in items {
                group.addTask { (a.id, await Self.refreshOne(a)) }
            }
            var out: [UUID: RefreshResult] = [:]
            for await (id, r) in group { out[id] = r }
            return out
        }
    }

    private static func refreshOne(_ a: ConfigAccount) async -> RefreshResult {
        await CredentialFile.refreshIfNeeded(a.configDir)
        async let ident = ClaudeCode.fetchIdentity(configDir: a.configDir, token: nil)
        let state: ClaudeCode.State
        if let token = CredentialFile.accessToken(a.configDir) {
            state = await ClaudeCode.fetchViaToken(token)
        } else {
            state = await ClaudeCode.fetchUsage(configDir: a.configDir)
        }
        return RefreshResult(state: state, identity: await ident)
    }

    // MARK: Session prime

    /// Kick off the 5h rolling window for this account now (one tiny message),
    /// then refresh so the new reset time / countdown shows immediately.
    public func startSession(_ account: ConfigAccount) async {
        await CredentialFile.refreshIfNeeded(account.configDir)
        _ = await ClaudeCode.primeSession(configDir: account.configDir)
    }

    // MARK: Auto-prime scheduling

    /// The 5h "current session" window for an account, if present.
    public func sessionWindow(of id: UUID, states: [UUID: ClaudeCode.State]) -> ClaudeCode.Window? {
        guard case .ok(let ws)? = states[id] else { return nil }
        return ws.first { $0.id == "five_hour" || $0.label.lowercased().contains("session") }
    }

    /// True if a 5h block is currently running (has a future reset, or shows usage).
    public func sessionActive(_ id: UUID, states: [UUID: ClaudeCode.State], now: Date) -> Bool {
        guard let w = sessionWindow(of: id, states: states) else { return false }
        if let r = w.resetAt, r > now { return true }
        return w.fraction > 0.02   // used but no parsed reset → still treat as active
    }

    /// Check every scheduled account and prime any that are within their
    /// active window but have no running 5h block. Cheap to call every minute.
    /// Returns the list of accounts that were primed this pass.
    @discardableResult
    public func checkSchedules(states: [UUID: ClaudeCode.State],
                               now: Date = Date()) async -> [ConfigAccount] {
        let cal = Calendar.current
        var primed: [ConfigAccount] = []
        for a in accounts {
            guard let s = a.schedule, s.enabled, hasCredential(a) else { continue }
            if s.weekdaysOnly {
                let wd = cal.component(.weekday, from: now)   // 1=Sun … 7=Sat
                if wd == 1 || wd == 7 { continue }
            }
            let dayStart = cal.startOfDay(for: now)
            let activeStart = dayStart.addingTimeInterval(Double(s.startMinutes) * 60)
            let activeEnd = activeStart.addingTimeInterval(Double(s.windowHours) * 3600)
            guard now >= activeStart, now <= activeEnd else { continue }
            if sessionActive(a.id, states: states, now: now) { continue }
            if let last = lastPrimed[a.id], now.timeIntervalSince(last) < 300 { continue }
            lastPrimed[a.id] = now
            await startSession(a)
            primed.append(a)
        }
        return primed
    }

    // MARK: Derived

    public func peak(of id: UUID, states: [UUID: ClaudeCode.State]) -> Double? {
        if case .ok(let w)? = states[id] { return w.map(\.fraction).max() }
        return nil
    }

    public func title(for account: ConfigAccount, identities: [UUID: ClaudeCode.Identity]) -> String {
        if let org = identities[account.id]?.orgName, !org.isEmpty { return org }
        return account.name
    }
}
