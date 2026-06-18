#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="Usage.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Usage "$APP/Contents/MacOS/Usage"

if [ -f "icon/AppIcon.icns" ]; then
  cp "icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Usage</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.claudeusagemonitor</string>
    <key>CFBundleName</key>
    <string>Usage</string>
    <key>CFBundleDisplayName</key>
    <string>Usage</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP" 2>/dev/null || true

echo "Built $APP"

# Install into /Applications (falls back to ~/Applications) so Spotlight
# indexes it under the name "Usage" and it can be launched from there.
INSTALL_DIR="/Applications"
if [ ! -w "$INSTALL_DIR" ]; then
  INSTALL_DIR="$HOME/Applications"
  mkdir -p "$INSTALL_DIR"
fi

# Kill the currently-running installed copy (if any) before replacing it.
pkill -f "$INSTALL_DIR/Usage.app/Contents/MacOS/Usage" 2>/dev/null || true

# Update IN PLACE rather than rm -rf + cp -R. WKWebView's persistent cookie
# storage is sensitive to the bundle directory's on-disk identity, not just
# CFBundleIdentifier — deleting and recreating the .app on every build was
# silently wiping the login session each time. rsync overwrites file
# contents without replacing the top-level directory entry itself.
mkdir -p "$INSTALL_DIR/Usage.app"
rsync -a --delete "$APP/" "$INSTALL_DIR/Usage.app/"

# Nudge Spotlight to re-index it immediately instead of waiting for its own schedule.
mdimport "$INSTALL_DIR/Usage.app" 2>/dev/null || true

# Icon caches are aggressive — force a refresh so the new icon shows up now
# instead of after a reboot.
touch "$INSTALL_DIR/Usage.app"
killall Dock 2>/dev/null || true

echo "Installed to $INSTALL_DIR/Usage.app"
