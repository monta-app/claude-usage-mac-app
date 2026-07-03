#!/bin/bash
# Builds the "Claude Usage" menu-bar app and packages it as a .app bundle
# (so notifications work and it runs without a Dock icon).
# Output: ./Claude Usage.app  (drag to /Applications, or `open` it).
set -euo pipefail
cd "$(dirname "$0")"

EXE="AnthropicUsageBar"                 # SPM product / internal executable name
DISPLAY_NAME="Claude Usage"             # user-facing name
BUNDLE_ID="com.local.anthropicusagebar" # kept stable so Keychain grants persist

echo "==> Building release binary…"
swift build -c release

APPDIR="$DISPLAY_NAME.app"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/Contents/MacOS"
mkdir -p "$APPDIR/Contents/Resources"

cp ".build/release/$EXE" "$APPDIR/Contents/MacOS/$EXE"

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
  SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '"[^"]*(Claude Usage|AnthropicUsageBar)[^"]*"' | head -1 | tr -d '"')
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
