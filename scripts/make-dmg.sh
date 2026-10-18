#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Macin.app"
DMG="build/Macin.dmg"
STAGE="build/dmg"

UNIVERSAL=1 SIGN_IDENTITY="${SIGN_IDENTITY:--}" ./scripts/build-app.sh release

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Macin" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Built: $DMG"
