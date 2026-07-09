#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/.build/PortsKiller.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
source "$ROOT_DIR/scripts/version.sh"
VERSION="$(resolve_portskiller_version)"
BUILD_NUMBER="${PORTSKILLER_BUILD:-$VERSION}"
DMG_PATH="$ROOT_DIR/.build/PortsKiller-$VERSION.dmg"

cd "$ROOT_DIR"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$ROOT_DIR/.build/release/PortsKiller" "$MACOS_DIR/PortsKiller"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>PortsKiller</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>com.md.PortsKiller</string>
  <key>CFBundleName</key>
  <string>PortsKiller</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

dot_clean -m "$APP_DIR" 2>/dev/null || true
find "$APP_DIR" -name '._*' -delete
find "$APP_DIR" -print0 | xargs -0 xattr -c 2>/dev/null || true
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

DMG_ROOT="$(mktemp -d)"
trap 'rm -rf "$DMG_ROOT"' EXIT
ditto --norsrc --noextattr "$APP_DIR" "$DMG_ROOT/PortsKiller.app"
ln -s /Applications "$DMG_ROOT/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "PortsKiller" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG_PATH"

echo "$APP_DIR"
echo "$DMG_PATH"
