# Sourced by install-device.sh and pull-diagnostics.sh. Sets DEVICE to $HIPPO_DEVICE or to the first
# paired, reachable iPhone that devicectl lists, and prints only the device's name.
pick_device() {
  if [[ -n "${HIPPO_DEVICE:-}" ]]; then
    DEVICE="$HIPPO_DEVICE"
    return
  fi
  local json
  json="$(mktemp -t hippo-devices)"
  xcrun devicectl list devices --json-output "$json" >/dev/null
  local picked
  picked="$(/usr/bin/python3 -I - "$json" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
for d in devices:
    hw, conn = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if hw.get("deviceType") == "iPhone" and conn.get("pairingState") == "paired" \
            and conn.get("tunnelState") != "unavailable":
        print(d["identifier"] + "\t" + d.get("deviceProperties", {}).get("name", "iPhone"))
        break
PY
)"
  rm -f "$json"
  if [[ -z "$picked" ]]; then
    echo "error: no connected iPhone found. Connect and unlock it, or set HIPPO_DEVICE." >&2
    exit 1
  fi
  DEVICE="${picked%%$'\t'*}"
  echo "Using device: ${picked#*$'\t'}"
}
