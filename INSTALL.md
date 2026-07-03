# Install — Claude Usage

A menu-bar app showing your Claude Code plan usage. Takes ~2 minutes.

## Requirements
- macOS 14+
- [Claude Code](https://claude.com/claude-code) installed and logged in (`claude`)
- Xcode command-line tools: `xcode-select --install`

## Steps

```bash
git clone git@github.com:monta-app/claude-usage-mac-app.git
cd claude-usage-mac-app
./build-app.sh
open "Claude Usage.app"
```

Look for the usage number in your menu bar (next to the clock). **Done.**

## Keep it running after reboot
System Settings → General → **Login Items** → **+** → select `Claude Usage.app`.

## Optional: install into Applications
```bash
cp -R "Claude Usage.app" /Applications/
```

---

## Add a second Max/Pro plan
1. Menu bar item → **Manage…** → **Add a plan**.
2. On the new plan → **Get token** → a Terminal runs `claude setup-token` → log in to *that* account → copy the printed token → paste it into the app.

The token is long-lived — you do this once per account.

---

## First-launch prompts
- **"Always Allow"** on the Keychain prompt, and **Allow** on any file-access prompt.
- To stop these recurring after each rebuild, create a one-time self-signed cert (Keychain Access → Certificate Assistant → Create a Certificate → name `Claude Usage`, Self Signed Root, **Code Signing**). `build-app.sh` picks it up automatically.

Full details: [README.md](README.md).
