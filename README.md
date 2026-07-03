# Anthropic Usage Bar

A tiny macOS menu-bar app that shows your **Claude Code plan usage** — one line per Max/Pro account, right next to the clock. Optionally shows your extra-usage **spend on top of the plan**.

The menu bar shows each account's highest limit, e.g. `56% · 40%` (⚠︎ at 100%). See **[INSTALL.md](INSTALL.md)** for the quick start.

---

## Install (2 minutes)

You need [Claude Code](https://claude.com/claude-code) installed and logged in, plus Xcode command-line tools (`xcode-select --install`).

```bash
git clone git@github.com:monta-app/claude-usage-mac-app.git
cd claude-usage-mac-app
./build-app.sh
open AnthropicUsageBar.app
```

That's it — look for the usage number in your menu bar. To keep it there after reboot: **System Settings → General → Login Items → +** → add `AnthropicUsageBar.app`.

To install it into Applications: `cp -R AnthropicUsageBar.app /Applications/`.

---

## What it shows

- **Claude Code plan limits** for the account you're logged into Claude Code as — session (5h) and weekly windows, as % bars. This is read from the CLI's own `claude -p "/usage"`, so **no setup** is needed for your primary account.
- The menu bar shows each account's **peak** usage (e.g. `56% · 40%`), turning red / ⚠︎ at 100%.

---

## Add a second plan

Different Max/Pro accounts live in different orgs, so each logs in separately.

1. Click the menu bar item → **Manage…**
2. **Add a plan** → give it a name (e.g. "Work Max").
3. On the new plan, click **Get token** → a Terminal window runs `claude setup-token` → log in to *that* account in the browser → **copy the token it prints** → paste it back in the app.

That token is **long-lived** (it doesn't expire), so you do this only once per account — no repeated logins. You can rename any plan in **Manage…** too.

---

## (Optional) Show spend on top of Max

To also see a member's **extra-usage spend** — the number at `claude.ai/admin-settings/usage`:

1. In **Manage… → a plan →** expand **"Show spend on top of Max"**.
2. Enter the member's **email** and an **Analytics API key**.
   - The org's **primary owner** creates the key at **claude.ai → Organization settings → API** (enable API access, create an Analytics key — scope `read:analytics`).
3. The app shows **"Spend this month: $X"** under that plan and appends it to the menu bar.

Requires a **Claude Enterprise (usage-based)** organization. On seat-based plans the figure reflects usage credits only.

---

## How it works (short version)

| Data | Source | Setup |
|---|---|---|
| Plan limit bars | `claude -p "/usage"` (the CLI) | none for primary; a long-lived token per extra account |
| Extra-usage spend | Claude Enterprise Analytics API (`/v1/organizations/analytics/user_cost_report`) | Analytics API key + member email |

Everything is stored locally: account names in `UserDefaults`, tokens/keys in the macOS **Keychain**. The app only **reads** usage — it never runs billable requests.

Refresh: plan limits every 5 min, spend every 30 min, or the ↻ button anytime.

---

## Stop the repeated permission prompts

Because the app is signed **ad-hoc** by default, macOS re-asks for Keychain/file access after every rebuild. To make "Always Allow" stick, create a one-time self-signed certificate:

- **Keychain Access → Certificate Assistant → Create a Certificate…**
- Name: `AnthropicUsageBar` · Identity Type: **Self Signed Root** · Type: **Code Signing**

`./build-app.sh` auto-detects it and signs with it from then on.

---

## Project layout

| File | Purpose |
|---|---|
| `App.swift` | `MenuBarExtra` + Manage window |
| `MenuContentView.swift` | Dropdown UI (account cards, bars, spend) |
| `ManageAccountsView.swift` | Add / rename / token / spend controls |
| `AccountStore.swift` | State, persistence, refresh loops |
| `ClaudeCodeUsage.swift` | Plan limits via CLI + token→API |
| `ClaudeCodeSpend.swift` | Extra-usage spend via Enterprise Analytics API |
| `ClaudeCodeAccounts.swift` | Account model + Terminal login helpers |
| `Keychain.swift` | Token / key storage |
| `build-app.sh` | Builds the `.app` bundle |
