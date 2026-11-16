#!/bin/zsh
# Builds HouseBridgePair.app, a tiny Mac Catalyst app that opens Apple's "Add Accessory" sheet (macOS 27+) so the
# HouseBridge bridge can be added to Home on a Mac whose Home.app has no Add Accessory command.
#
# Usage: scripts/build-pair.sh [--sign "Apple Development: …"] [--profile path/to.provisionprofile]
#   Default is ad-hoc signed with no entitlements: the system sheet asks you to type the setup code.
#   With --sign and --profile it also gets com.apple.developer.homekit.allow-setup-payload (a restricted
#   entitlement from an Apple Developer account) so `--use-payload --uri X-HM://…` skips the typing.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="-"; PROFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign) IDENTITY="${2:?identity required}"; shift 2 ;;
    --profile) PROFILE="${2:?profile required}"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

SDK="$(xcrun --show-sdk-path)"
IOS="$SDK/System/iOSSupport"
APP="HouseBridgePair.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"

for ARCH in arm64 x86_64; do
  swiftc -module-name HouseBridgePair -target "$ARCH-apple-ios27.0-macabi" -sdk "$SDK" -O \
    -F "$IOS/System/Library/Frameworks" -I "$IOS/usr/lib/swift" -L "$IOS/usr/lib" \
    Tools/HouseBridgePair/main.swift -o ".build/HouseBridgePair-$ARCH"
done
lipo -create .build/HouseBridgePair-arm64 .build/HouseBridgePair-x86_64 -output "$APP/Contents/MacOS/HouseBridgePair"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.housebridge.pair</string>
  <key>CFBundleName</key><string>HouseBridgePair</string>
  <key>CFBundleExecutable</key><string>HouseBridgePair</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Finds the HouseBridge HomeKit bridge on your network so it can be added to Home.</string>
  <key>NSBonjourServices</key><array><string>_hap._tcp</string></array>
  <key>UIApplicationSceneManifest</key><dict>
    <key>UIApplicationSupportsMultipleScenes</key><false/>
    <key>UISceneConfigurations</key><dict>
      <key>UIWindowSceneSessionRoleApplication</key><array><dict>
        <key>UISceneConfigurationName</key><string>Default</string>
        <key>UISceneDelegateClassName</key><string>HouseBridgePair.SceneDelegate</string>
      </dict></array>
    </dict>
  </dict>
</dict></plist>
PLIST

if [[ -n "$PROFILE" ]]; then
  cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
  cat > .build/pair.entitlements <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.developer.homekit.allow-setup-payload</key><true/>
</dict></plist>
ENT
  codesign --force --sign "$IDENTITY" --entitlements .build/pair.entitlements "$APP"
else
  codesign --force --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
ditto -c -k --keepParent "$APP" HouseBridgePair.zip
echo "Built $APP (+ HouseBridgePair.zip). Run: open -n $APP --args --code <setup code>"
