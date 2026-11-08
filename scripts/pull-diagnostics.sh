#!/usr/bin/env bash
# Copies the redacted diagnostics.json from the App Group on a connected iPhone (design §3.5) to
# build/diagnostics.json and prints it. Set HIPPO_DEVICE to choose a device.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/pick-device.sh

pick_device
mkdir -p build
xcrun devicectl device copy from --device "$DEVICE" \
  --domain-type appGroupDataContainer --domain-identifier group.com.jorgeper.hippo \
  --source "Library/Application Support/Hippo/diagnostics.json" --destination build/diagnostics.json
cat build/diagnostics.json
echo
