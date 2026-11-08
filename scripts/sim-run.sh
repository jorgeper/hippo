#!/usr/bin/env bash
# Builds Hippo for the iOS Simulator, boots it, installs and launches the app.
#   --seed               copy fixtures/packages/captures into the app's store first (recovery registers them)
#   --screenshot <path>  save a screenshot 3 s after launch
# Set HIPPO_SIM to choose the simulator (default "iPhone 18 Pro").
set -euo pipefail
cd "$(dirname "$0")/.."

SIM="${HIPPO_SIM:-iPhone 18 Pro}"
BUNDLE_ID=com.jorgeper.hippo
APP_GROUP=group.com.jorgeper.hippo
seed=false
screenshot=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --seed) seed=true; shift ;;
    --screenshot) [[ $# -ge 2 ]] || { echo "error: --screenshot needs a path" >&2; exit 1; }
                  screenshot="$2"; shift 2 ;;
    *) echo "usage: $0 [--seed] [--screenshot <path>]" >&2; exit 1 ;;
  esac
done

xcodegen generate
xcodebuild -project Hippo.xcodeproj -scheme Hippo -configuration Debug \
  -destination "platform=iOS Simulator,name=$SIM" -derivedDataPath build/DerivedData build

# The simulator's UDID, preferring a booted one if several share the name.
udid="$(xcrun simctl list devices available --json | /usr/bin/python3 -I -c '
import json, sys
name = sys.argv[1]
devices = [d for ds in json.load(sys.stdin)["devices"].values() for d in ds if d["name"] == name]
devices.sort(key=lambda d: d["state"] != "Booted")
print(devices[0]["udid"] if devices else "")
' "$SIM")"
[[ -n "$udid" ]] || { echo "error: no available simulator named \"$SIM\"" >&2; exit 1; }

xcrun simctl bootstatus "$udid" -b >/dev/null
open -b com.apple.iphonesimulator 2>/dev/null || true  # show the window when the Simulator app is installed
xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$udid" build/DerivedData/Build/Products/Debug-iphonesimulator/Hippo.app

if $seed; then
  group="$(xcrun simctl get_app_container "$udid" "$BUNDLE_ID" "$APP_GROUP")"
  captures="$group/Library/Application Support/Hippo/captures"
  mkdir -p "$captures"
  cp -R fixtures/packages/captures/ "$captures/"
  echo "Seeded fixture captures."
fi

xcrun simctl launch "$udid" "$BUNDLE_ID"

if [[ -n "$screenshot" ]]; then
  mkdir -p "$(dirname "$screenshot")"
  sleep 3
  xcrun simctl io "$udid" screenshot "$screenshot"
fi
