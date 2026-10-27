#!/bin/zsh
# Builds a self-contained HouseBridge.app (+ HouseBridge.zip for moving it to another Mac).
#
#   HouseBridge.app/Contents/MacOS/HouseBridge     menu bar app (double-click)
#   HouseBridge.app/Contents/MacOS/housebridgectl  command-line tool, same build
#
# Universal (Apple silicon + Intel). Links only system frameworks; the Swift runtime ships with macOS 15+,
# so nothing else needs installing on the target Mac.
# Usage: scripts/bundle.sh [--sign "Developer ID Application: Your Name (TEAMID)"]
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="-"   # ad-hoc by default
if [[ "${1:-}" == "--sign" ]]; then IDENTITY="${2:?identity required}"; fi

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release --disable-sandbox $ARCHS --product HouseBridgeMenu
swift build -c release --disable-sandbox $ARCHS --product housebridgectl
BIN="$(swift build -c release --disable-sandbox $ARCHS --show-bin-path)"

APP="HouseBridge.app"
rm -rf "$APP" HouseBridge.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN/HouseBridgeMenu" "$APP/Contents/MacOS/HouseBridge"
cp "$BIN/housebridgectl"  "$APP/Contents/MacOS/housebridgectl"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.housebridge</string>
  <key>CFBundleName</key><string>HouseBridge</string>
  <key>CFBundleDisplayName</key><string>HouseBridge</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>HouseBridge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>HouseBridge talks to your Lutron, Hue and UniFi devices on the local network.</string>
</dict></plist>
PLIST

codesign --force --deep --options runtime --sign "$IDENTITY" "$APP/Contents/MacOS/housebridgectl"
codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

# ditto keeps the signature and attributes intact; plain zip/cp-over-network can break them.
ditto -c -k --keepParent "$APP" HouseBridge.zip

echo
echo "Built $APP and HouseBridge.zip"
lipo -archs "$APP/Contents/MacOS/HouseBridge" | sed 's/^/  architectures: /'
echo "  non-system libraries linked: $(otool -L "$APP/Contents/MacOS/HouseBridge" | grep 'compatibility version' | grep -vE '^\s+(/System/|/usr/lib/)' | wc -l | tr -d ' ')"
