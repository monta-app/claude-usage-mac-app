#!/bin/bash
# Builds the `ccu` CLI and installs it to a prefix (default ~/.local/bin).
# Mirrors build-app.sh: bakes the git SHA into the binary so `ccu update`
# can compare against the latest GitHub release.
#
# Usage:
#   ./install-cli.sh                 # installs to ~/.local/bin/ccu
#   ./install-cli.sh --prefix /usr/local
#   ./install-cli.sh --prefix ~/apps
set -euo pipefail
cd "$(dirname "$0")"

PREFIX="$HOME/.local/bin"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2;;
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
echo "    Make sure $PREFIX is on your PATH. Test with: ccu --version"
echo "    Update later with: ccu update"
