import ArgumentParser
import Foundation
import AnthropicUsageCore

/// `ccu` — manage multiple Claude Code accounts and view plan usage from the
/// command line. Designed for SSH / headless workflows where the menu-bar app
/// can't run: each account is a self-contained `CLAUDE_CONFIG_DIR` with its own
/// `.credentials.json`, so the same file-per-account model the GUI uses also
/// works over SSH (no Keychain, no GUI).
///
/// Accounts live under ~/.claude-usage/cc/<uuid>/, index at ~/.claude-usage/accounts.json.
/// Share that dir between machines (e.g. via a dotfiles sync) to keep accounts
/// consistent across hosts.
@main
struct CCU: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ccu",
        abstract: "Manage multiple Claude Code accounts and view plan usage (SSH-friendly).",
        version: "ccu \(CCUVersion.sha)",
        subcommands: [
            List.self, Add.self, Login.self, Usage.self, Refresh.self,
            Prime.self, Env.self, Use.self, Rename.self, Remove.self,
            Schedule.self, Run.self, Update.self
        ]
    )

    /// Shared manager bound to the default base dir (~/.claude-usage).
    static func manager() -> AccountsManager {
        AccountsManager(baseDir: AccountsManager.defaultBaseDir())
    }

    /// Resolve an account by name, or exit with a helpful message.
    static func require(_ m: AccountsManager, _ name: String) -> ConfigAccount {
        guard let a = m.find(name) else {
            let known = m.accounts.map(\.name).joined(separator: ", ")
            CCU.exit(withError: ValidationError("No account named \"\(name)\".\(known.isEmpty ? "" : " Known: \(known).") Run: ccu add \(name)"))
        }
        return a
    }
}

// MARK: - list

extension CCU {
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list", abstract: "List accounts and current usage bars.")

        func run() async throws {
            let m = CCU.manager()
            if m.accounts.isEmpty {
                print("No accounts yet. Add one with: ccu login <name>")
                return
            }
            let results = await m.refreshAll()
            for (i, a) in m.accounts.enumerated() {
                if i > 0 { print() }
                let r = results[a.id]
                Printers.account(a, state: r?.state, identity: r?.identity)
            }
        }
    }
}

// MARK: - add

extension CCU {
    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add", abstract: "Create an empty account slot (no login yet).")

        @Argument var name: String

        func run() throws {
            let m = CCU.manager()
            if m.find(name) != nil {
                throw ValidationError("An account named \"\(name)\" already exists.")
            }
            let a = m.add(name: name)
            print("Added \"\(name)\". Log in with: ccu login \(name)")
            print("  config dir: \(a.configDir)")
        }
    }
}

// MARK: - login

extension CCU {
    struct Login: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "login",
            abstract: "Run `claude /login` for an account (creates it if missing). SSH-friendly: prints a URL to open in a local browser.")

        @Argument var name: String

        func run() throws {
            let m = CCU.manager()
            let account = m.find(name) ?? m.add(name: name)
            print("Logging in as \"\(name)\" into \(account.configDir)")
            print("Open the printed URL in a browser, then come back here.\n")
            let env = ["CLAUDE_CONFIG_DIR": account.configDir]
            let status = Shell.exec(command: "claude", arguments: ["/login"], env: env)
            throw ExitCode(status)
        }
    }
}

// MARK: - usage

extension CCU {
    struct Usage: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "usage", abstract: "Show usage bars for one account (or all).")

        @Argument var name: String?

        func run() async throws {
            let m = CCU.manager()
            if let name {
                let a = CCU.require(m, name)
                let r = await m.refresh(a)
                Printers.account(a, state: r.state, identity: r.identity)
            } else {
                try await List().run()
            }
        }
    }
}

// MARK: - refresh

extension CCU {
    struct Refresh: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "refresh", abstract: "Refresh OAuth tokens for accounts (cron-able).")

        @Argument var name: String?

        func run() async throws {
            let m = CCU.manager()
            if let name {
                let a = CCU.require(m, name)
                let refreshed = await CredentialFile.refreshIfNeeded(a.configDir)
                print("\(name): \(refreshed ? "token refreshed" : "token still fresh")")
            } else {
                for a in m.accounts {
                    let refreshed = await CredentialFile.refreshIfNeeded(a.configDir)
                    print("\(a.name): \(refreshed ? "refreshed" : "fresh")")
                }
            }
        }
    }
}

// MARK: - prime

extension CCU {
    struct Prime: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "prime",
            abstract: "Kick off the 5h session window now (one tiny message).")

        @Argument var name: String

        func run() async throws {
            let m = CCU.manager()
            let a = CCU.require(m, name)
            print("Priming 5h session for \"\(name)\"…")
            await m.startSession(a)
            print("Done. Run `ccu usage \(name)` to see the new window.")
        }
    }
}

// MARK: - env

extension CCU {
    struct Env: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "env",
            abstract: "Print `export CLAUDE_CONFIG_DIR=...` for sourcing. Usage: eval \"$(ccu env <name>)\"")

        @Argument var name: String

        @Flag(name: .shortAndLong, help: "Print a `unset` line instead (for clearing).")
        var unset = false

        func run() throws {
            let m = CCU.manager()
            let a = CCU.require(m, name)
            if unset {
                print("unset CLAUDE_CONFIG_DIR")
            } else {
                print("export CLAUDE_CONFIG_DIR=\(Shell.quote(a.configDir))")
            }
        }
    }
}

// MARK: - use

extension CCU {
    struct Use: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "use",
            abstract: "Run a command with CLAUDE_CONFIG_DIR set to an account's dir.")

        @Argument var name: String
        @Argument(parsing: .captureForPassthrough) var command: [String]

        func run() throws {
            // `.captureForPassthrough` may or may not include the `--` separator
            // depending on ArgumentParser version; strip a leading one so the
            // command array starts at the real command.
            var cmd = command
            if cmd.first == "--" { cmd.removeFirst() }
            guard !cmd.isEmpty else {
                throw ValidationError("Provide a command to run, e.g. ccu use work -- claude")
            }
            let m = CCU.manager()
            let a = CCU.require(m, name)
            var env = ProcessInfo.processInfo.environment
            env["CLAUDE_CONFIG_DIR"] = a.configDir
            let status = Shell.exec(command: cmd[0],
                                    arguments: Array(cmd.dropFirst()),
                                    env: env)
            throw ExitCode(status)
        }
    }
}

// MARK: - rename

extension CCU {
    struct Rename: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rename", abstract: "Rename an account.")

        @Argument var name: String
        @Argument var newName: String

        func run() throws {
            let m = CCU.manager()
            let a = CCU.require(m, name)
            m.rename(a, to: newName)
            print("Renamed \"\(name)\" → \"\(newName)\".")
        }
    }
}

// MARK: - rm

extension CCU {
    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rm", abstract: "Delete an account and its login dir.")

        @Argument var name: String

        @Flag(name: .shortAndLong, help: "Skip the confirmation prompt.")
        var force = false

        func run() throws {
            let m = CCU.manager()
            let a = CCU.require(m, name)
            if !force {
                print("Delete \"\(name)\" and its login at \(a.configDir)? [y/N] ", terminator: "")
                let reply = readLine()?.lowercased() ?? ""
                guard reply == "y" || reply == "yes" else {
                    print("Cancelled.")
                    return
                }
            }
            m.remove(a)
            print("Deleted \"\(name)\".")
        }
    }
}

// MARK: - schedule

extension CCU {
    struct Schedule: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "schedule",
            abstract: "Configure the daily auto-prime schedule for an account.")

        @Argument var name: String

        @Option(name: .long, help: "Start time, 24h \"H:MM\" (e.g. 8:00). Omit to disable the schedule.")
        var start: String?

        @Option(name: .long, help: "Hours to keep chaining fresh 5h blocks (default 9).")
        var hours: Int?

        @Flag(name: .long, help: "Run every day. (Default: Mon–Fri only.)")
        var allWeek: Bool = false

        func run() throws {
            let m = CCU.manager()
            let a = CCU.require(m, name)

            guard let start else {
                m.setSchedule(a, PrimeSchedule(enabled: false))
                print("Schedule disabled for \"\(name)\".")
                return
            }
            let parts = start.split(separator: ":")
            guard parts.count == 2, let h = Int(parts[0]), let mn = Int(parts[1]),
                  (0...23).contains(h), (0...59).contains(mn) else {
                throw ValidationError("Invalid --start \"\(start)\". Use 24h H:MM, e.g. 8:00 or 17:30.")
            }
            let wh = hours ?? 9
            guard (1...16).contains(wh) else {
                throw ValidationError("--hours must be 1...16")
            }
            let s = PrimeSchedule(enabled: true,
                                  startMinutes: h * 60 + mn,
                                  windowHours: wh,
                                  weekdaysOnly: !allWeek)
            m.setSchedule(a, s)
            print("Schedule for \"\(name)\": auto-prime \(s.startLabel)–\(s.endLabel)\(s.weekdaysOnly ? " · weekdays" : "")")
            print("Tip: run `ccu run` from cron every minute to drive it:")
            print("  * * * * * /path/to/ccu run >> ~/.claude-usage/ccu-run.log 2>&1")
        }
    }
}

// MARK: - run (cron entry point)

extension CCU {
    /// One pass of the auto-prime scheduler. Idempotent and cheap; intended to
    /// be called from cron once a minute. For each scheduled account within its
    /// active window with no running 5h block, primes one. Does nothing when the
    /// account is already active (your own messages keep the block alive).
    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run", abstract: "One scheduler tick (cron-able). Primes any due account.")

        @Flag(name: .long, help: "Print what happened even when nothing primed.")
        var verbose = false

        func run() async throws {
            let m = CCU.manager()
            if m.accounts.isEmpty { return }

            // Need current usage states to know whether a 5h block is running.
            let states = await m.refreshAll().mapValues { $0.state }
            let primed = await m.checkSchedules(states: states)

            if primed.isEmpty {
                if verbose { print("[ccu run] nothing to prime") }
                return
            }
            let names = primed.map(\.name).joined(separator: ", ")
                + " (primed). Their 5h window now starts."
            print("[ccu run] \(names)")
        }
    }
}

// MARK: - update

extension CCU {
    /// Check GitHub Releases for a newer `ccu` binary and atomically replace
    /// this one if available. No external deps (curl + Foundation JSON); works
    /// over SSH. The "latest" release is rolling, so we compare the baked-in
    /// git SHA against the release's `target_commitish` (the commit it was
    /// built from).
    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "update",
            abstract: "Check GitHub for a newer ccu binary and replace this one if available.")

        @Flag(name: .long, help: "Print what would happen, don't change anything.")
        var dryRun = false

        func run() async throws {
            let repo = CCUVersion.repo
            let apiURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!

            print("Checking \(repo) for updates…")
            let (data, resp) = try await get(apiURL)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw ValidationError("Could not reach GitHub (HTTP \(resp)).")
            }

            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ValidationError("Unexpected response from GitHub.")
            }
            let remoteSHA = String((root["target_commitish"] as? String ?? "").prefix(7))
            let publishedAt = root["published_at"] as? String ?? ""
            let assets = root["assets"] as? [[String: Any]] ?? []
            guard let asset = assets.first(where: { $0["name"] as? String == CCUVersion.assetName }),
                  let downloadURLString = asset["browser_download_url"] as? String,
                  let downloadURL = URL(string: downloadURLString) else {
                throw ValidationError("No \"\(CCUVersion.assetName)\" asset on the latest release.")
            }
            print("  local  : \(CCUVersion.sha)")
            print("  remote : \(remoteSHA)  (published \(publishedAt))")

            if remoteSHA.isEmpty || remoteSHA == CCUVersion.sha {
                print("Already up to date.")
                return
            }

            let exePath = CommandLine.arguments.first ?? ""
            guard !exePath.isEmpty, exePath != "/" else {
                throw ValidationError("Couldn't resolve the ccu binary path (\(exePath)).")
            }
            let exeURL = URL(fileURLWithPath: exePath)

            if dryRun {
                print("Dry run: would download \(downloadURLString) and replace \(exePath).")
                return
            }


            print("Downloading \(downloadURLString)…")
            let (dlData, dlResp) = try await get(downloadURL)
            guard let http = dlResp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw ValidationError("Download failed (HTTP \(dlResp)).")
            }

            // The asset is a tar.gz (the workflow tar+gz's the binary so
            // GitHub doesn't mislabel a bare "ccu" as text). Extract the
            // binary from it before replacing.
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ccu-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let archiveURL = tempDir.appendingPathComponent(CCUVersion.assetName)
            try dlData.write(to: archiveURL)

            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-xzf", archiveURL.path, "-C", tempDir.path]
            try tar.run()
            tar.waitUntilExit()
            guard tar.terminationStatus == 0 else {
                throw ValidationError("Couldn't extract the archive (tar exit \(tar.terminationStatus)).")
            }
            let extractedBin = tempDir.appendingPathComponent("ccu")
            guard FileManager.default.fileExists(atPath: extractedBin.path) else {
                throw ValidationError("Archive didn't contain a `ccu` binary.")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                 ofItemAtPath: extractedBin.path)

            // Atomic replace. On Unix you can rename over a running binary;
            // the currently running process keeps its inode until it exits.
            _ = try? FileManager.default.removeItem(at: exeURL)
            try FileManager.default.moveItem(at: extractedBin, to: exeURL)
            try? FileManager.default.removeItem(at: tempDir)
            print("Updated \(exePath) → \(remoteSHA). Re-run ccu to use the new binary.")
        }

        private func get(_ url: URL) async throws -> (Data, URLResponse) {
            var req = URLRequest(url: url)
            req.setValue("ccu/\(CCUVersion.sha)", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 30
            return try await URLSession.shared.data(for: req)
        }
    }
}

// MARK: - Shell helpers

enum Shell {
    /// Run a command inheriting the caller's stdio (interactive-friendly).
    /// Returns the process exit status (0 on success).
    static func exec(command: String, arguments: [String], env: [String: String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: command)
        task.arguments = arguments
        var fullEnv = ProcessInfo.processInfo.environment
        for (k, v) in env { fullEnv[k] = v }
        task.environment = fullEnv
        do {
            try task.run()
        } catch {
            FileHandle.standardError.write(Data("ccu: couldn't run \(command): \(error)\n".utf8))
            return 127
        }
        task.waitUntilExit()
        return task.terminationStatus
    }

    /// Shell-quote a string for safe embedding (used by `ccu env`).
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Output formatting

enum Printers {
    static func account(_ a: ConfigAccount, state: ClaudeCode.State?, identity: ClaudeCode.Identity?) {
        let title = identity?.label ?? a.name
        print(title)
        let cred = CredentialFile.exists(a.configDir) ? "" : "  (no login — run: ccu login \(a.name))"
        if !cred.isEmpty { print(cred); return }

        guard let state else {
            print("  (no data)")
            return
        }

        switch state {
        case .loading:
            print("  loading…")
        case .cliMissing:
            print("  claude CLI not found. Install: https://claude.com/claude-code")
        case .notLoggedIn:
            print("  not logged in — run: ccu login \(a.name)")
        case .expired:
            print("  login expired — run: ccu login \(a.name)")
        case .rateLimited:
            print("  throttled (429) — will retry")
        case .stats(let cost):
            print("  no plan limits · total cost \(Format.usd(cost))")
        case .error(let m):
            print("  error: \(m)")
        case .ok(let windows):
            for w in windows { print(bar(w)) }
        }

        if let s = a.schedule, s.enabled {
            print("  schedule: auto-prime \(s.startLabel)–\(s.endLabel)\(s.weekdaysOnly ? " · weekdays" : "")")
        }
    }

    private static func bar(_ w: ClaudeCode.Window) -> String {
        let pct = Int((w.fraction * 100).rounded())
        let label = w.label.padding(toLength: 24, withPad: " ", startingAt: 0)
        let bar = asciiBar(w.fraction, width: 20)
        var suffix = ""
        if let at = w.resetAt {
            suffix = "  resets \(Format.clock(at))"
        } else if let r = w.resetText {
            suffix = "  resets \(r)"
        }
        return "  \(label) \(pct)% \(bar)\(suffix)"
    }

    private static func asciiBar(_ f: Double, width: Int) -> String {
        let clamped = min(max(f, 0), 1)
        let filled = Int((clamped * Double(width)).rounded())
        return String(repeating: "█", count: max(0, min(width, filled)))
             + String(repeating: "░", count: max(0, width - filled))
    }
}
