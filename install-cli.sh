#!/bin/bash
# Builds the `ccu` CLI and installs it to a prefix (default ~/.local/bin).
# Mirrors build-app.sh: bakes the git SHA + version into the binary so
# `ccu update` can compare against the latest GitHub release.
#
# Also installs the shell hook that makes `ccu switch <name>` apply to every
# open terminal. Detects zsh and bash and appends an idempotent block to the
# relevant rc file (~/.zshrc / ~/.bashrc). Use --no-hook to skip.
#
# Usage:
#   ./install-cli.sh                         # ~/.local/bin/ccu + shell hook
#   ./install-cli.sh --prefix /usr/local
#   ./install-cli.sh --prefix ~/apps
#   ./install-cli.sh --no-hook               # skip shell hook install
set -euo pipefail
cd "$(dirname "$0")"

PREFIX="$HOME/.local/bin"
INSTALL_HOOK=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2;;
    --no-hook) INSTALL_HOOK=0; shift;;
    *) echo "Unknown arg: $1" >&2; exit 2;;
  esac
done

# Embed the git short SHA + version into the binary so `ccu update` can
# compare against the rolling "latest" release. Falls back to "dev" if git
# is unavailable. Local builds use 1.<commit-count>-dev (the authoritative
# N is only computed in CI, where it can query GitHub).
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
N="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
VERSION="1.${N}-dev"

cat > Sources/ccu/Version.swift <<SWIFT
import Foundation

public enum CCUVersion {
    public static let sha: String = "$SHA"
    public static let version: String = "$VERSION"
    public static let repo = "monta-app/claude-usage-mac-app"
    public static let assetName = "ccu.tar.gz"
}
SWIFT

echo "==> Building ccu (SHA=$SHA VERSION=$VERSION)…"
swift build -c release

# Restore the default Version.swift so the working tree stays clean. The
# SHA is already baked into the built binary; the source file doesn't need
# to keep it.
git checkout -- Sources/ccu/Version.swift 2>/dev/null || true

mkdir -p "$PREFIX"
install -m 0755 .build/release/ccu "$PREFIX/ccu"

echo "==> Installed: $PREFIX/ccu"

# --- Shell hook install ---------------------------------------------------
# Appends a small precmd hook to the user's rc file so `ccu switch <name>`
# applies to every open terminal. Idempotent: a marker comment is used so
# re-running install-cli.sh doesn't duplicate the block.
install_shell_hook() {
  [[ $INSTALL_HOOK -eq 0 ]] && { echo "==> Shell hook skipped (--no-hook)."; return; }

  local marker="# ccu shell integration (managed by install-cli.sh)"
  local hook

  # Detect the user's shell and pick the rc file + hook syntax.
  local shell="${SHELL##*/}"   # basename of $SHELL (zsh / bash)
  local rc
  case "$shell" in
    zsh) rc="$HOME/.zshrc" ;;
    bash) rc="$HOME/.bashrc" ;;
    *) echo "==> Shell '$shell' not auto-supported. Add this to your rc file:"; "$PREFIX/ccu" init "$shell" 2>/dev/null || "$PREFIX/ccu" init zsh; return ;;
  esac

  # Idempotent: skip if the marker is already present.
  if [[ -f "$rc" ]] && grep -qF "$marker" "$rc" 2>/dev/null; then
    echo "==> Shell hook already in $rc — skipping."
    return
  fi

  # Build the hook block. We use the `ccu init <shell>` output wrapped in
  # the marker so future re-installs can detect and replace it if needed.
  hook="$("$PREFIX/ccu" init "$shell")"

  {
    echo ""
    echo "$marker"
    echo "$hook"
  } >> "$rc"

  echo "==> Shell hook added to $rc."
  echo "    Reload with: source $rc"
  echo "    Then 'ccu switch <name>' will apply to every terminal."
}

install_shell_hook

echo "==> Done."
echo "    Make sure $PREFIX is on your PATH. Test with: ccu --version"
echo "    Update later with: ccu update"
