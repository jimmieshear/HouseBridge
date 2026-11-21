#!/bin/zsh
# Builds HouseBridgeProbe.app (Mac Catalyst, HomeKit entitlement) with Xcode automatic signing. Needs Xcode signed in
# to the developer team, and every Mac that will run it registered under Devices in the developer portal.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project Tools/HouseBridgeProbe/HouseBridgeProbe.xcodeproj -scheme HouseBridgeProbe -configuration Release \
  -destination 'platform=macOS,variant=Mac Catalyst' -allowProvisioningUpdates -derivedDataPath .build/probe build
rm -rf HouseBridgeProbe.app && cp -R .build/probe/Build/Products/Release-maccatalyst/HouseBridgeProbe.app .
ditto -c -k --keepParent HouseBridgeProbe.app HouseBridgeProbe.zip
echo "Built HouseBridgeProbe.app (+ .zip). Run: HouseBridgeProbe.app/Contents/MacOS/HouseBridgeProbe > homekit-dump.txt"
