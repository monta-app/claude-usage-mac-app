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
        version: "ccu \(CCUVersion.version) (\(CCUVersion.sha))",
        // Order matters for `ccu --help`: most-used first, setup/admin last.
        // Group logically: see → switch → manage → per-shell → automation → setup.
        subcommands: [
            // Everyday
            List.self,        // see all accounts + usage
            Current.self,    // which is active
            Switch.self,      // switch (all terminals)
            Usage.self,      // single-account detail
            // Account management
            Add.self,         // add a slot
            Login.self,       // log in
            Rename.self,      // rename
            Remove.self,      // delete
            // Per-shell / one-shot
            Env.self,         // export line for sourcing
            Use.self,         // run a command under an account
            // Automation (cron)
            Prime.self,       // kick off a 5h session now
            Schedule.self,    // configure daily auto-prime
            Run.self,         // one scheduler tick
            Refresh.self,     // keep tokens alive
            // Setup / admin
            Init.self,        // install shell hook
            Update.self,      // self-update from GitHub
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

        @Flag(name: .long, help: "Re-fetch account identities via `claude auth status` (slow; otherwise cached).")
        var refreshIdentity = false

        func run() async throws {
            let m = CCU.manager()
            if m.accounts.isEmpty {
                print("No accounts yet. Add one with: ccu login <name>")
                return
            }
            if refreshIdentity {
                for a in m.accounts { _ = await m.refreshIdentity(a) }
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
    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Create an account slot. Use --current to capture the login you're already using.")

        @Argument var name: String

        @Flag(name: .long, help: "Capture the current default login (~/.claude/.credentials.json) into this account's dir. No re-authentication needed.")
        var current = false

        func run() async throws {
            let m = CCU.manager()
            if m.find(name) != nil {
                throw ValidationError("An account named \"\(name)\" already exists.")
            }
            let a = m.add(name: name)

            if current {
                let defaultCreds = NSString(string: NSHomeDirectory()).appendingPathComponent(".claude/.credentials.json")
                guard FileManager.default.fileExists(atPath: defaultCreds) else {
                    print("Added \"\(name)\" but no default login found at ~/.claude/.credentials.json.")
                    print("Log in with: ccu login \(name)")
                    return
                }
                let dest = a.configDir + "/.credentials.json"
                try FileManager.default.copyItem(atPath: defaultCreds, toPath: dest)
                print("Added \"\(name)\" — captured login from ~/.claude/.credentials.json.")
                print("  config dir: \(a.configDir)")
                print("  Use it with: eval \"$(ccu env \(name))\"")
                // Fetch identity in the background so we don't block. The cache
                // will be populated for the next `ccu list`. Run `ccu list
                // --refresh-identity` if you want it immediately.
                Task { _ = await m.refreshIdentity(a) }
            } else {
                print("Added \"\(name)\". Log in with: ccu login \(name)")
                print("  config dir: \(a.configDir)")
            }
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

        func run() async throws {
            let m = CCU.manager()
            let account = m.find(name) ?? m.add(name: name)
            print("Logging in as \"\(name)\" into \(account.configDir)")
            print("Open the printed URL in a browser, then come back here.\n")
            let env = ["CLAUDE_CONFIG_DIR": account.configDir]
            let status = Shell.exec(command: "claude", arguments: ["/login"], env: env)
            guard status == 0 else { throw ExitCode(status) }
            // Cache the identity so `ccu list` doesn't have to re-fetch it
            // (a ~5s Node.js subprocess) on every invocation.
            if let ident = await m.refreshIdentity(account) {
                print("\n✅ Logged in as \(ident.label ?? name).")
            }
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
                // No name → show all. Inline rather than delegating to List()
                // (which has its own @Flag/Argument properties that can't be
                // constructed empty).
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

// MARK: - switch (global, all terminals via a precmd hook)

extension CCU {
    /// Switch the active account globally. Writes the account's configDir to
    /// `~/.claude-usage/active`; the zsh precmd hook (installed via
    /// `ccu init zsh`) re-reads it on every prompt, so every open terminal
    /// picks up the change at its next prompt render (~instant).
    struct Switch: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "switch",
            abstract: "Switch the active account globally (all terminals). Run `ccu init zsh` once to enable.")

        @Argument var name: String?

        @Flag(name: .long, help: "Switch back to the default ~/.claude login (no CLAUDE_CONFIG_DIR).")
        var off = false

        func run() throws {
            let m = CCU.manager()
            let marker = m.baseDir.appendingPathComponent("active")

            if off || name == nil {
                try? FileManager.default.removeItem(at: marker)
                print("Switched to default (~/.claude). New prompts in every terminal will pick this up.")
                return
            }
            guard let n = name, let a = m.find(n) else {
                throw ValidationError("No account named \"\(name ?? "")\". Known: \(m.accounts.map(\.name).joined(separator: ", "))")
            }
            try a.configDir.write(to: marker, atomically: true, encoding: .utf8)
            print("Switched to \"\(a.name)\". New prompts in every terminal will pick this up.")
            print("  CLAUDE_CONFIG_DIR=\(a.configDir)")
            if CredentialFile.exists(a.configDir) == false {
                print("  ⚠️ no login in this account yet — run: ccu login \(a.name)")
            }
        }
    }
}

// MARK: - current

extension CCU {
    /// Print which account is currently active (per the global marker file),
    /// or "default" if none is set. Reads the same file the precmd hook reads.
    struct Current: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "current", abstract: "Print the currently active account name (or 'default').")

        func run() throws {
            let m = CCU.manager()
            let marker = m.baseDir.appendingPathComponent("active")
            guard let dir = try? String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                  let acct = m.accounts.first(where: { $0.configDir == dir }) else {
                print("default")
                return
            }
            print(acct.name)
        }
    }
}

// MARK: - init (shell integration hook)

extension CCU {
    /// Print the shell hook so `eval "$(ccu init zsh)"` (or appending to
    /// .zshrc) wires up the precmd that makes `ccu switch` apply to every
    /// open terminal. The hook is tiny and idempotent.
    struct Init: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "init",
            abstract: "Print shell integration hook. Usage: eval \"$(ccu init zsh)\" or add to ~/.zshrc.")

        @Argument var shell: String

        func run() throws {
            switch shell.lowercased() {
            case "zsh":
                print(Self.zshHook)
            case "bash":
                print(Self.bashHook)
            default:
                throw ValidationError("Unsupported shell: \(shell). Use 'zsh' or 'bash'.")
            }
        }

        static let zshHook = """
        # ccu shell integration — `eval "$(ccu init zsh)"` or add to ~/.zshrc
        _ccu_precmd() {
          local f="$HOME/.claude-usage/active"
          if [[ -f "$f" ]]; then
            local d="$(cat "$f")"
            [[ -n "$d" ]] && export CLAUDE_CONFIG_DIR="$d" || unset CLAUDE_CONFIG_DIR
          else
            unset CLAUDE_CONFIG_DIR
          fi
        }
        autoload -Uz add-zsh-hook
        add-zsh-hook precmd _ccu_precmd
        """

        static let bashHook = """
        # ccu shell integration — add to ~/.bashrc
        _ccu_precmd() {
          local f="$HOME/.claude-usage/active"
          if [[ -f "$f" ]]; then
            local d="$(cat "$f")"
            [[ -n "$d" ]] && export CLAUDE_CONFIG_DIR="$d" || unset CLAUDE_CONFIG_DIR
          else
            unset CLAUDE_CONFIG_DIR
          fi
        }
        PROMPT_COMMAND="_ccu_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
        """
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

            // Resolve the real executable path. `CommandLine.arguments.first`
            // (argv[0]) is whatever the shell passed — often just "ccu" when
            // invoked from PATH, which would replace ./ccu in the CWD instead
            // of the installed binary. Use `_NSGetExecutablePath` (macOS) to
            // get the actual path the kernel loaded.
            var exeSize: UInt32 = UInt32(PATH_MAX)
            var exeBuf = [CChar](repeating: 0, count: Int(PATH_MAX))
            let rc = exeBuf.withUnsafeMutableBufferPointer { ptr -> Int32 in
                guard let base = ptr.baseAddress else { return -1 }
                return _NSGetExecutablePath(base, &exeSize)
            }
            guard rc == 0 else {
                throw ValidationError("Couldn't resolve the ccu binary path (_NSGetExecutablePath rc=\(rc)).")
            }
            let raw = String(cString: exeBuf)
            let exeURL = URL(fileURLWithPath: raw).resolvingSymlinksInPath()
            let exePath = exeURL.path

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
        // Always lead with the account name the user chose. Identity (email
        // / org / subscription type) is shown as a subtitle if it adds info
        // the name doesn't already convey.
        print(a.name)
        if let identity {
            let extras = [identity.email, identity.orgName].compactMap { $0 }
            if !extras.isEmpty {
                print("  \(extras.joined(separator: " · "))")
            }
            if let sub = identity.subscriptionType, !sub.isEmpty {
                print("  plan: \(sub)")
            }
        }
        let cred = CredentialFile.exists(a.configDir) ? "" : "    (no login — run: ccu login \(a.name))"
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
