#!/bin/bash
# Builds AnthropicUsageBar and packages it as a proper .app bundle so that
# macOS UserNotifications work and the app runs without a Dock icon.
# Output: ./AnthropicUsageBar.app  (drag it to /Applications, or run open on it)
set -euo pipefail
cd "$(dirname "$0")"

APP="AnthropicUsageBar"
BUNDLE_ID="com.local.anthropicusagebar"

echo "==> Building release binary…"
swift build -c release

APPDIR="$APP.app"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/Contents/MacOS"
mkdir -p "$APPDIR/Contents/Resources"

cp ".build/release/$APP" "$APPDIR/Contents/MacOS/$APP"

cat > "$APPDIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP</string>
    <key>CFBundleDisplayName</key>       <string>Anthropic Usage</string>
    <key>CFBundleExecutable</key>        <string>$APP</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>           <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHumanReadableCopyright</key>  <string>Local build</string>
</dict>
</plist>
PLIST

# Stable signing keeps macOS's "Always Allow" (keychain) and file-access grants
# across rebuilds. Ad-hoc signing changes identity every build, so every rebuild
# re-prompts. Use a stable identity if one exists.
#   $CODESIGN_ID           — explicit identity name, or
#   an identity named "AnthropicUsageBar" in your keychain (see note below), or
#   fall back to ad-hoc.
SIGN_ID="${CODESIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
  SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"[^"]*AnthropicUsageBar[^"]*"' | head -1 | tr -d '"')
fi
if [ -n "$SIGN_ID" ]; then
  echo "==> Signing with stable identity: $SIGN_ID"
  codesign --force --deep --sign "$SIGN_ID" "$APPDIR" && echo "   signed (Always Allow will persist across rebuilds)"
else
  echo "==> Ad-hoc code signing (Always Allow will re-prompt after each rebuild)"
  echo "   To stop the repeated keychain/Documents prompts, create a one-time"
  echo "   self-signed Code Signing certificate named 'AnthropicUsageBar':"
  echo "     Keychain Access → Certificate Assistant → Create a Certificate…"
  echo "       Name: AnthropicUsageBar | Identity Type: Self Signed Root | Type: Code Signing"
  echo "   Then re-run ./build-app.sh — it will pick it up automatically."
  codesign --force --deep --sign - "$APPDIR" 2>/dev/null || echo "   (codesign skipped)"
fi

echo "==> Done: $(pwd)/$APPDIR"
echo "    Run it with:  open \"$(pwd)/$APPDIR\""
echo "    Install with: cp -R \"$APPDIR\" /Applications/"
