#!/bin/bash
# Builds the "Claude Usage" menu-bar app and packages it as a .app bundle
# (so notifications work and it runs without a Dock icon).
# Output: ./Claude Usage.app  (drag to /Applications, or `open` it).
set -euo pipefail
cd "$(dirname "$0")"

EXE="AnthropicUsageBar"                 # SPM product / internal executable name
DISPLAY_NAME="Claude Usage"             # user-facing name
BUNDLE_ID="com.local.anthropicusagebar" # kept stable so Keychain grants persist

# Embed the git short SHA + date-based version into the app and CLI before
# building, so `ccu update` and the app's update checker can compare against
# the latest GitHub release. Falls back to "dev" if git is unavailable.
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
VERSION="$(date -u +%Y%m%d-%H%M%S)-${SHA}"
cat > Sources/AnthropicUsageBar/Version.swift <<SWIFT
import Foundation

enum AppVersion {
    static let sha: String = "$SHA"
    static let version: String = "$VERSION"
    static let repo = "monta-app/claude-usage-mac-app"
}
SWIFT
cat > Sources/ccu/Version.swift <<SWIFT
import Foundation

public enum CCUVersion {
    public static let sha: String = "$SHA"
    public static let version: String = "$VERSION"
    public static let repo = "monta-app/claude-usage-mac-app"
    public static let assetName = "ccu.tar.gz"
}
SWIFT

echo "==> Building release binary (SHA=$SHA VERSION=$VERSION)…"
swift build -c release

# Restore the default Version.swift files so the working tree stays clean.
# The SHA is already baked into the built binaries.
git checkout -- Sources/AnthropicUsageBar/Version.swift Sources/ccu/Version.swift 2>/dev/null || true

APPDIR="$DISPLAY_NAME.app"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/Contents/MacOS"
mkdir -p "$APPDIR/Contents/Resources"

cp ".build/release/$EXE" "$APPDIR/Contents/MacOS/$EXE"

# App icon (Finder, ⌘-Tab, Login Items). Rebuild AppIcon.icns from icon.svg if
# the source is newer or the icns is missing.
if [ -f icon.svg ] && { [ ! -f AppIcon.icns ] || [ icon.svg -nt AppIcon.icns ]; }; then
  echo "==> Rendering AppIcon.icns from icon.svg…"
  rm -rf AppIcon.iconset && mkdir AppIcon.iconset
  for pair in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
              "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
              "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
    set -- $pair
    rsvg-convert -w "$1" -h "$1" icon.svg -o "AppIcon.iconset/$2.png"
  done
  iconutil -c icns AppIcon.iconset -o AppIcon.icns
  rm -rf AppIcon.iconset
fi
if [ -f AppIcon.icns ]; then
  cp AppIcon.icns "$APPDIR/Contents/Resources/AppIcon.icns"
fi

cat > "$APPDIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key>       <string>$DISPLAY_NAME</string>
    <key>CFBundleExecutable</key>        <string>$EXE</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>           <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundleIconName</key>          <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHumanReadableCopyright</key>  <string>Local build</string>
</dict>
</plist>
PLIST

# Stable signing keeps macOS's "Always Allow" (Keychain) and file-access grants
# across rebuilds. Ad-hoc signing changes identity every build, so every rebuild
# re-prompts. Use a stable identity if one exists.
#   $CODESIGN_ID  — explicit identity name, or
#   an identity named "Claude Usage" / "AnthropicUsageBar" in your keychain, or
#   fall back to ad-hoc.
SIGN_ID="${CODESIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
  # `|| true` so a no-match grep under `set -o pipefail` doesn't abort the build.
  SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '"[^"]*(Claude Usage|AnthropicUsageBar)[^"]*"' | head -1 | tr -d '"' || true)
fi
if [ -n "$SIGN_ID" ]; then
  echo "==> Signing with stable identity: $SIGN_ID"
  codesign --force --deep --sign "$SIGN_ID" "$APPDIR" && echo "   signed (Always Allow will persist across rebuilds)"
else
  echo "==> Ad-hoc code signing (Always Allow will re-prompt after each rebuild)"
  echo "   To stop the repeated Keychain/Documents prompts, create a one-time"
  echo "   self-signed Code Signing certificate named 'Claude Usage':"
  echo "     Keychain Access → Certificate Assistant → Create a Certificate…"
  echo "       Name: Claude Usage | Identity Type: Self Signed Root | Type: Code Signing"
  echo "   Then re-run ./build-app.sh — it will pick it up automatically."
  codesign --force --deep --sign - "$APPDIR" 2>/dev/null || echo "   (codesign skipped)"
fi

echo "==> Done: $(pwd)/$APPDIR"
echo "    Run it with:  open \"$(pwd)/$APPDIR\""
echo "    Install with: cp -R \"$APPDIR\" /Applications/"
