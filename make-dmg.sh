#!/bin/bash
# Builds "Claude Usage.app" and packages it into a drag-to-install .dmg.
# Output: ./Claude-Usage.dmg
set -euo pipefail
cd "$(dirname "$0")"

APP="Claude Usage.app"
DMG="Claude-Usage.dmg"
VOL="Claude Usage"

echo "==> Building app…"
./build-app.sh

echo "==> Staging DMG contents…"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag target

echo "==> Creating ${DMG}…"
rm -f "$DMG"
hdiutil create -volname "$VOL" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG"

rm -rf "$STAGE"
echo "==> Done: $(pwd)/$DMG"
