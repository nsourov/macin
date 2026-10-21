#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="build/Macin.app"

ARCH_FLAGS=()
if [[ -n "${UNIVERSAL:-}" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c "$CONFIG" "${ARCH_FLAGS[@]}"
BIN="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)/MacFootprint"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Macin"

ICONSET="build/AppIcon.iconset"
if [[ ! -f Resources/icon-1024.png || scripts/make-icon.swift -nt Resources/icon-1024.png ]]; then
    mkdir -p Resources
    swift scripts/make-icon.swift Resources/icon-1024.png
fi
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Macin</string>
    <key>CFBundleDisplayName</key><string>Macin</string>
    <key>CFBundleIdentifier</key><string>com.macin.app</string>
    <key>CFBundleExecutable</key><string>Macin</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>0.1.3</string>
    <key>CFBundleVersion</key><string>4</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSDesktopFolderUsageDescription</key><string>Macin measures folder sizes on your Desktop. Nothing leaves your Mac.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>Macin measures folder sizes in Documents. Nothing leaves your Mac.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>Macin measures folder sizes in Downloads. Nothing leaves your Mac.</string>
</dict>
</plist>
PLIST

if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development|Developer ID Application/ { print $2; exit }')
fi
codesign --force --deep --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built: $APP"
