#!/usr/bin/env bash
set -Eeuo pipefail

# Finder-launched .command files close only after a successful build. Any
# failure leaves the terminal open so the complete diagnostic remains visible.
finish_terminal() {
  local status=$?
  trap - EXIT
  if [[ "$status" -ne 0 ]]; then
    printf '\n iOS Debug build failed (exit %s); this window will stay open.\n' "$status" >&2
    if [[ -t 0 ]]; then
      read -r -p 'Press Enter to close this window...' _ || true
    fi
  fi
  exit "$status"
}
trap finish_terminal EXIT

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA="${IOS_DERIVED_DATA_DIR:-$PROJECT_ROOT/.build/ios-debug-derived-data}"
STAMP="$(date +%Y%m%d-%H%M%S)"
DEVELOPMENT_TEAM_ID="${IOS_DEVELOPMENT_TEAM:-6YY8Y34949}"
BUNDLE_ID="com.ztransfer.ios"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: iOS Debug packaging requires macOS and Xcode." >&2
  exit 1
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "ERROR: xcodebuild was not found. Install Xcode and select it with xcode-select." >&2
  exit 1
fi
if [[ ! -d "$PROJECT_ROOT/ios/ZTransfer.xcodeproj" ]]; then
  echo "ERROR: iOS Xcode project was not found: $PROJECT_ROOT/ios/ZTransfer.xcodeproj" >&2
  exit 1
fi

if [[ "${IOS_CLEAN_DERIVED_DATA:-0}" == "1" ]]; then
  rm -rf "$DERIVED_DATA"
fi
mkdir -p "$DERIVED_DATA"

cd "$PROJECT_ROOT"
echo "Building and signing iOS Debug app..."
xcodebuild \
  -project "$PROJECT_ROOT/ios/ZTransfer.xcodeproj" \
  -scheme ZTransfer \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM_ID" \
  -allowProvisioningUpdates \
  build

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphoneos/ZTransfer.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: signed Debug app was not found: $APP_PATH" >&2
  exit 1
fi
/usr/bin/codesign --verify --deep --strict "$APP_PATH"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Info.plist" 2>/dev/null || true)"
if [[ -z "$VERSION" ]]; then
  echo "ERROR: CFBundleShortVersionString is missing from the app." >&2
  exit 1
fi
ARTIFACT_BASENAME="ZTransfer-ios-debug-${VERSION}-${STAMP}"
APP_ARTIFACT="$SCRIPT_DIR/${ARTIFACT_BASENAME}.app"
IPA_ARTIFACT="$SCRIPT_DIR/${ARTIFACT_BASENAME}.ipa"
if [[ -e "$APP_ARTIFACT" || -e "$IPA_ARTIFACT" ]]; then
  echo "ERROR: timestamped artifact already exists; refusing to overwrite it." >&2
  exit 1
fi

ditto "$APP_PATH" "$APP_ARTIFACT"
PAYLOAD_DIR="$DERIVED_DATA/Payload"
rm -rf "$PAYLOAD_DIR"
mkdir -p "$PAYLOAD_DIR"
ditto "$APP_PATH" "$PAYLOAD_DIR/ZTransfer.app"
(cd "$DERIVED_DATA" && /usr/bin/zip -qry "$IPA_ARTIFACT" Payload)
/usr/bin/unzip -tqq "$IPA_ARTIFACT"
echo "APP: $APP_ARTIFACT"
echo "IPA: $IPA_ARTIFACT"

# Pick an explicitly requested device first, otherwise the first available
# CoreDevice. A disconnected phone does not make the build fail; when a device
# is found, install and launch are required and failures keep this window open.
DEVICE_ID="${IOS_DEVICE_ID:-}"
LEGACY_DEVICE_ID=""
if [[ -z "$DEVICE_ID" ]] && command -v xcrun >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  DEVICE_JSON="$DERIVED_DATA/devices.json"
  if xcrun devicectl list devices --json-output "$DEVICE_JSON" >/dev/null 2>&1; then
    DEVICE_ID="$(python3 - "$DEVICE_JSON" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1], encoding="utf-8")).get("result", {}).get("devices", [])
except (OSError, ValueError, TypeError):
    devices = []
for device in devices:
    props = device.get("hardwareProperties", {})
    connection = device.get("connectionProperties", {})
    if props.get("platform") == "iOS" and connection.get("tunnelState") == "available":
        print(device.get("identifier", ""))
        break
PY
)"
  fi
fi

if [[ -n "$DEVICE_ID" ]]; then
  echo "Installing on iOS device $DEVICE_ID..."
  xcrun devicectl device install app --device "$DEVICE_ID" "$APP_ARTIFACT" --timeout 120
  echo "Launching ZTransfer..."
  xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" --timeout 60
  echo "Installed and launched on $DEVICE_ID."
else
  # Older iOS/CoreDevice combinations can be visible to xcdevice while their
  # devicectl tunnel is unavailable. Keep the legacy fallback from the former
  # iOS build script so a USB phone is still installed and launched detached.
  if command -v xcrun >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    LEGACY_JSON="$DERIVED_DATA/xcdevice.json"
    if xcrun xcdevice list --timeout=5 > "$LEGACY_JSON" 2>/dev/null; then
      LEGACY_DEVICE_ID="$(python3 - "$LEGACY_JSON" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError, TypeError):
    devices = []
for device in devices:
    if (not device.get("simulator") and device.get("available") and
            device.get("platform") == "com.apple.platform.iphoneos"):
        print(device.get("identifier", ""))
        break
PY
)"
    fi
  fi
  if [[ -n "$LEGACY_DEVICE_ID" ]]; then
    if ! command -v ios-deploy >/dev/null 2>&1; then
      echo "ERROR: iPhone detected but ios-deploy is unavailable. Install it with: brew install ios-deploy" >&2
      exit 1
    fi
    echo "Installing on legacy iOS device $LEGACY_DEVICE_ID..."
    ios-deploy --id "$LEGACY_DEVICE_ID" --bundle "$APP_ARTIFACT" --no-wifi --nostart
    if ! command -v idevicedebug >/dev/null 2>&1; then
      echo "ERROR: App installed, but idevicedebug is unavailable for detached launch. Install libimobiledevice." >&2
      exit 1
    fi
    echo "Launching ZTransfer..."
    idevicedebug -u "$LEGACY_DEVICE_ID" --detach run "$BUNDLE_ID"
    # A successful debugserver reply only confirms that launch was accepted.
    # Check that the app survives detaching before reporting success.
    sleep 2
    PID_OUTPUT="$(ios-deploy --id "$LEGACY_DEVICE_ID" --get_pid --bundle_id "$BUNDLE_ID" 2>&1)"
    if [[ ! "$PID_OUTPUT" =~ pid:[[:space:]]*[1-9][0-9]* ]]; then
      printf '%s\n' "$PID_OUTPUT" >&2
      echo "ERROR: App installed, but no running process was found after launch." >&2
      exit 1
    fi
    echo "Installed and launched on $LEGACY_DEVICE_ID."
  else
    echo "No available iOS device found; skipping installation and launch."
  fi
fi

echo "iOS Debug build complete."
