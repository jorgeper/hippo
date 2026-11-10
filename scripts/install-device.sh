#!/usr/bin/env bash
# Builds Hippo and installs it on a connected iPhone (design §3.5). Free Personal Team installs
# expire after 7 days; run this again to reinstall. Captures survive as long as the app isn't deleted.
# Set HIPPO_DEVICE to a devicectl device identifier or name to choose a device.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/pick-device.sh

if ! grep -Eq '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]{10}[[:space:]]*$' Config/Local.xcconfig 2>/dev/null; then
  echo "error: Config/Local.xcconfig must set DEVELOPMENT_TEAM to your Apple team ID." >&2
  echo "       Copy Config/Local.example.xcconfig to Config/Local.xcconfig and fill it in." >&2
  exit 1
fi

if [ ! -f Config/Secrets.xcconfig ]; then
  echo "warning: Dropbox is not configured; run make dropbox-setup" >&2
fi

xcodegen generate
xcodebuild -project Hippo.xcodeproj -scheme Hippo -configuration Debug \
  -destination generic/platform=iOS -derivedDataPath build/DerivedData -allowProvisioningUpdates build

pick_device
xcrun devicectl device install app --device "$DEVICE" build/DerivedData/Build/Products/Debug-iphoneos/Hippo.app

echo "Installed. Free-team installs expire after 7 days; run make device again. Your captures are kept."
