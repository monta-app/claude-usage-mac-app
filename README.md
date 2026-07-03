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

## Add a second plan

Different Max/Pro accounts live in different orgs, so each logs in separately.

1. Click the menu bar item → **Manage…** → **Add a plan**.
2. On the new plan, click **Get token** → a Terminal window runs `claude setup-token` → log in to *that* account in the browser → **copy the token it prints** → paste it back in the app.

That token is **long-lived** (it doesn't expire), so you do this only once per account — no repeated logins. Each plan is labelled automatically with its real account (**org · email**) read from the CLI — no manual naming.

---

## How it works (short version)

Plan limits come from the CLI's own `claude -p "/usage"`; the account label comes from `claude auth status`. No setup for your primary account; a long-lived token per extra account. Tokens live in the macOS **Keychain**; the app only **reads** usage — it never runs billable requests. Refresh: every 5 min, or the ↻ button anytime.

---

## Stop the repeated permission prompts

Because the app is signed **ad-hoc** by default, macOS re-asks for Keychain/file access after every rebuild. To make "Always Allow" stick, create a one-time self-signed certificate:

- **Keychain Access → Certificate Assistant → Create a Certificate…**
- Name: `Claude Usage` · Identity Type: **Self Signed Root** · Type: **Code Signing**

`./build-app.sh` auto-detects it and signs with it from then on.

---

## Project layout

| File | Purpose |
|---|---|
| `App.swift` | `MenuBarExtra` + Manage window |
| `MenuContentView.swift` | Dropdown UI (account cards, bars) |
| `ManageAccountsView.swift` | Add plan / token controls |
| `AccountStore.swift` | State, persistence, refresh loops |
| `ClaudeCodeUsage.swift` | Plan limits + account identity via CLI |
| `ClaudeCodeAccounts.swift` | Account model + Terminal login helpers |
| `Keychain.swift` | Token / key storage |
| `build-app.sh` | Builds the `.app` bundle |
