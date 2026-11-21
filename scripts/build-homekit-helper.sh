#!/bin/zsh
# Usage: scripts/build-homekit-helper.sh [--no-copy]
# Builds HouseBridgeHomeKit.app, the Mac Catalyst helper that forwards HomeKit smoke/CO/temperature/humidity readings
# to HouseBridge. Needs Xcode signed in to the developer team (automatic signing makes the HomeKit profile) and
# every Mac that will run it registered under Devices in the developer portal.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project Tools/HouseBridgeHomeKit/HouseBridgeHomeKit.xcodeproj -scheme HouseBridgeHomeKit -configuration Release \
  -destination 'platform=macOS,variant=Mac Catalyst' -allowProvisioningUpdates -derivedDataPath .build/homekit-helper build
BUILT=.build/homekit-helper/Build/Products/Release-maccatalyst/HouseBridgeHomeKit.app
# bundle.sh embeds the app straight from .build; a copy in the repo root is only made when this is run by hand.
if [[ "${1:-}" == "--no-copy" ]]; then echo "Built $BUILT"; exit 0; fi
rm -rf HouseBridgeHomeKit.app && cp -R "$BUILT" .
echo "Built HouseBridgeHomeKit.app. HouseBridge normally starts it itself from inside HouseBridge.app; to try it alone: HouseBridgeHomeKit.app/Contents/MacOS/HouseBridgeHomeKit --stay"
