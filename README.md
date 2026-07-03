# Claude Usage

A tiny macOS menu-bar app that shows your **Claude Code plan usage** — one line per Max/Pro account, right next to the clock.

The menu bar shows each account's highest limit, e.g. `56% · 40%` (⚠︎ at 100%). See **[INSTALL.md](INSTALL.md)** for the quick start.

---

## Install (2 minutes)

You need [Claude Code](https://claude.com/claude-code) installed and logged in, plus Xcode command-line tools (`xcode-select --install`).

```bash
git clone git@github.com:monta-app/claude-usage-mac-app.git
cd claude-usage-mac-app
./build-app.sh
open "Claude Usage.app"
```

That's it — look for the usage number in your menu bar. To keep it there after reboot: **System Settings → General → Login Items → +** → add `Claude Usage.app`.

To install it into Applications: `cp -R "Claude Usage.app" /Applications/`.

---

## What it shows

- **Claude Code plan limits** for the account you're logged into Claude Code as — session (5h) and weekly windows, as % bars. This is read from the CLI's own `claude -p "/usage"`, so **no setup** is needed for your primary account.
- The menu bar shows each account's **peak** usage (e.g. `56% · 40%`), turning red / ⚠︎ at 100%.

---

## Multiple accounts (both logged in at once)

See usage for several Claude accounts simultaneously — safely, with no Keychain access.

1. **Manage… → Add another account** → name it.
2. Click **Log in** on it → a Terminal runs `claude /login` in that account's own config dir → sign in as that account.
3. Both accounts now show in the dropdown, each with its own bars; the menu bar shows both peaks (e.g. `56% · 40%`).

Each extra account lives in its own `CLAUDE_CONFIG_DIR`, so it's an independent login that **never touches your Default login or the Keychain**. Your **Default** account is the one Claude Code and Conductor use.

**To make Claude Code / Conductor use an extra account** in a given terminal or Conductor session, set its `CLAUDE_CONFIG_DIR` to that account's dir (shown by the app). The Default account needs no env var.

## How it works

Reads plan limits via `claude -p "/usage"` (per config dir) and the account name via `claude auth status`. The app only reads usage and opens the official `claude /login` — it never touches the Keychain, stores no tokens, and never modifies a login. Refresh every 5 min or ↻.

