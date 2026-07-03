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

## Switch between accounts

The app registers each Claude account and lets you **swap the active login with one click** — so Claude Code, Conductor, and anything else using your Claude login all use the account you pick.

1. **Manage… → Log in…** → log in to an account in the browser.
2. Click **Add current login** to register it.
3. Repeat for your other account(s).
4. Then just click an account in the menu-bar dropdown (or **Switch to** in Manage) to swap. The menu bar shows the **active** account's plan usage.

It works by snapshotting each account's Claude Code login and restoring it on swap (all local, in the macOS Keychain). Only one account is active at a time — which is all any tool can use anyway. First read/write of the login triggers a Keychain prompt: **Always Allow**.

## How it works (short version)

Plan limits come from `claude -p "/usage"`; the account label from `claude auth status`. Switching writes a saved login snapshot into Claude Code's Keychain item (`Claude Code-credentials`). Everything is local; the app only reads usage — it never runs billable requests. Refresh: every 5 min, or ↻.

