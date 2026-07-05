import Foundation

/// Reads Claude Code subscription plan limits by running the CLI's own
/// `/usage` command non-interactively (`claude -p "/usage"`) and parsing its
/// output. This is far more robust than calling the usage HTTP endpoint
/// directly: the CLI owns auth + caching and isn't rate-limited by us, and
/// there's no token for the app to store or leak.
///
/// Tradeoff: it reports whichever account Claude Code is currently logged in
/// as (Claude Code holds one login at a time).
enum ClaudeCode {

    struct Window: Identifiable {
        let id: String        // the label, used as identity
        let label: String
        let fraction: Double  // 0...1
        let resetText: String?   // raw text as printed by the CLI
        let resetAt: Date?       // parsed reset instant, for a live countdown
    }

    enum State {
        case ok([Window])
        case stats(costUSD: Double)   // token/API mode: "Total cost: $X" but no limit bars
        case notLoggedIn
        case expired                  // token rejected (401)
        case rateLimited              // 429 — token valid, throttled
        case cliMissing
        case error(String)
        case loading
    }

    // MARK: Token → direct API (long-lived token, no logout)

    /// Fetch limits via the usage HTTP endpoint using a long-lived token
    /// (from `claude setup-token`). This path doesn't log out and doesn't
    /// touch Claude Code's keychain login.
    static func fetchViaToken(_ token: String) async -> State {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("claude-cli/usage-bar", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .error("No response") }
            if http.statusCode == 401 { return .expired }
            if http.statusCode == 429 { return .rateLimited }
            guard (200..<300).contains(http.statusCode) else { return .error("HTTP \(http.statusCode)") }
            return parseAPI(data)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private static func parseAPI(_ data: Data) -> State {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .error("Unexpected API response")
        }
        let limits = (root["rate_limits"] as? [String: Any])
            ?? ((root["usage"] as? [String: Any])?["rate_limits"] as? [String: Any])
        guard let limits else { return .error("No limits in API response") }

        var windows: [Window] = []
        for (key, value) in limits {
            guard let d = value as? [String: Any] else { continue }
            let raw = (d["utilization"] as? Double) ?? Double((d["utilization"] as? Int) ?? 0)
            let frac = raw > 1 ? raw / 100.0 : raw
            var resetText: String? = nil
            let secs = (d["resets_at"] as? Double) ?? Double((d["resets_at"] as? Int) ?? 0)
            if secs > 0 {
                let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"
                resetText = f.string(from: Date(timeIntervalSince1970: secs))
            }
            let resetAt = secs > 0 ? Date(timeIntervalSince1970: secs) : nil
            windows.append(Window(id: key, label: humanise(key),
                                  fraction: min(max(frac, 0), 1), resetText: resetText, resetAt: resetAt))
        }
        guard !windows.isEmpty else { return .error("No limit windows in response") }
        windows.sort { $0.id < $1.id }
        return .ok(windows)
    }

    private static func humanise(_ key: String) -> String {
        switch key {
        case "five_hour": return "Current session"
        case "seven_day": return "Current week (all models)"
        case "seven_day_opus", "seven_day_oauth_opus": return "Current week (Opus)"
        case "seven_day_fable", "seven_day_oauth_fable": return "Current week (Fable)"
        default: return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    // MARK: Public

    struct Identity: Equatable {
        var email: String?
        var orgName: String?
        /// Best label for display: email, else org name.
        var label: String? { email ?? orgName }
    }

    /// The logged-in account identity for a given auth context, via
    /// `claude auth status --json`. Same auth resolution as usage: a token
    /// wins; otherwise the config dir (nil = default ~/.claude login).
    static func fetchIdentity(configDir: String?, token: String?) async -> Identity? {
        await Task.detached(priority: .utility) { blockingIdentity(configDir: configDir, token: token) }.value
    }

    private static func blockingIdentity(configDir: String?, token: String?) -> Identity? {
        guard let bin = resolveClaude() else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: bin)
        task.arguments = ["auth", "status", "--json"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        if let token { env["CLAUDE_CODE_OAUTH_TOKEN"] = token }
        else if let configDir { env["CLAUDE_CONFIG_DIR"] = configDir }
        task.environment = env
        task.currentDirectoryURL = URL(fileURLWithPath: neutralWorkdir())
        let out = Pipe(); task.standardOutput = out; task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        let deadline = DispatchTime.now() + 20
        let killer = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: deadline, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit(); killer.cancel()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Identity(email: root["email"] as? String, orgName: root["orgName"] as? String)
    }

    /// Start (prime) the 5h rolling window for a login by sending one minimal
    /// message. The block begins at the first message and runs exactly 5 hours,
    /// so this is how you kick the clock off on demand. Negligible usage.
    /// Returns true if the message was accepted.
    @discardableResult
    static func primeSession(configDir: String?) async -> Bool {
        await Task.detached(priority: .utility) { blockingPrime(configDir: configDir) }.value
    }

    private static func blockingPrime(configDir: String?) -> Bool {
        guard let bin = resolveClaude() else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: bin)
        // A trivial prompt is enough to open the 5h block; keep output tiny.
        task.arguments = ["-p", "Reply with just: ok"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        if let configDir { env["CLAUDE_CONFIG_DIR"] = configDir }
        task.environment = env
        task.currentDirectoryURL = URL(fileURLWithPath: neutralWorkdir())
        task.standardOutput = Pipe(); task.standardError = Pipe()
        do { try task.run() } catch { return false }
        let deadline = DispatchTime.now() + 60
        let killer = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: deadline, execute: killer)
        task.waitUntilExit(); killer.cancel()
        return task.terminationStatus == 0
    }

    /// Fetch limits for a specific login. `configDir == nil` uses the default
    /// (`~/.claude`) — your primary Claude Code login. A path selects an
    /// independent login via `CLAUDE_CONFIG_DIR`.
    static func fetchUsage(configDir: String? = nil) async -> State {
        await Task.detached(priority: .utility) { blockingFetch(configDir: configDir) }.value
    }

    // MARK: Implementation

    /// A stable, app-owned empty directory to run the CLI in — avoids touching
    /// the user's Documents/home (which triggers a macOS access prompt).
    private static func neutralWorkdir() -> String {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AnthropicUsageBar/run", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private static func resolveClaude() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func blockingFetch(configDir: String?) -> State {
        guard let bin = resolveClaude() else { return .cliMissing }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: bin)
        task.arguments = ["-p", "/usage"]
        // GUI apps launch with a minimal PATH; give the CLI a sane one.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        if let configDir { env["CLAUDE_CONFIG_DIR"] = configDir }  // independent login
        task.environment = env
        // Run in a neutral empty dir so Claude Code doesn't scan the launch
        // cwd (Documents/home) and trip macOS's file-access (TCC) prompt.
        task.currentDirectoryURL = URL(fileURLWithPath: neutralWorkdir())

        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()

        do { try task.run() } catch { return .error("Couldn't run claude: \(error.localizedDescription)") }

        // Hard timeout so a wedged CLI can't hang the poll.
        let deadline = DispatchTime.now() + 30
        let killer = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: deadline, execute: killer)

        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        killer.cancel()

        let text = String(data: data, encoding: .utf8) ?? ""
        if text.isEmpty { return .error("No output from claude /usage") }
        return parse(text)
    }

    // MARK: Parsing

    // Matches: "Current session: 100% used · resets Jul 2 at 6:09pm (America/New_York)"
    // and the same without a reset clause.
    private static let line = try! NSRegularExpression(
        pattern: #"^(.+?):\s*(\d+)%\s*used(?:\s*[·-]\s*resets\s*(.+?))?\s*$"#,
        options: [.anchorsMatchLines])

    // Matches: "Total cost:            $13.01"
    private static let costLine = try! NSRegularExpression(
        pattern: #"Total cost:\s*\$([0-9][0-9,]*\.?[0-9]*)"#,
        options: [.caseInsensitive])

    /// Parse a CLI reset string like "Jul 5 at 6:09pm (America/New_York)" into
    /// an absolute Date. Best-effort: returns nil if the wording changes, in
    /// which case the UI falls back to showing the raw text.
    static func parseReset(_ raw: String) -> Date? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        // Pull a trailing "(America/New_York)" timezone, if present.
        if let r = s.range(of: #"\(([^)]+)\)\s*$"#, options: .regularExpression) {
            let name = String(s[r]).trimmingCharacters(in: CharacterSet(charactersIn: "() "))
            if let z = TimeZone(identifier: name) { cal.timeZone = z }
            s = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        s = s.replacingOccurrences(of: " at ", with: " ")

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = cal.timeZone
        for fmt in ["MMM d h:mma", "MMM d h:mm a", "MMM d, h:mma", "MMM d, h:mm a"] {
            df.dateFormat = fmt
            guard let d = df.date(from: s) else { continue }
            var comps = cal.dateComponents([.month, .day, .hour, .minute], from: d)
            comps.year = cal.component(.year, from: Date())
            guard let withYear = cal.date(from: comps) else { continue }
            // No year in the string: if it lands well in the past, it's next year.
            if withYear.timeIntervalSinceNow < -86_400 {
                comps.year! += 1
                return cal.date(from: comps)
            }
            return withYear
        }
        return nil
    }

    private static func parse(_ text: String) -> State {
        let lower = text.lowercased()
        if lower.contains("please run /login") || lower.contains("not logged in")
            || lower.contains("log in") && lower.contains("subscription") == false && !lower.contains("%") {
            return .notLoggedIn
        }

        var windows: [Window] = []
        let ns = text as NSString
        for m in line.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let label = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard let pct = Double(ns.substring(with: m.range(at: 2))) else { continue }
            var reset: String? = nil
            if m.range(at: 3).location != NSNotFound {
                reset = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces)
            }
            windows.append(Window(id: label, label: label,
                                  fraction: min(max(pct / 100.0, 0), 1),
                                  resetText: reset, resetAt: reset.flatMap(parseReset)))
        }

        if windows.isEmpty {
            // No "% used" limit lines → stats/token mode. Surface the
            // "Total cost: $X" figure if present.
            if let m = costLine.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                let raw = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: "")
                if let cost = Double(raw) { return .stats(costUSD: cost) }
            }
            return .notLoggedIn
        }
        return .ok(windows)
    }
}
