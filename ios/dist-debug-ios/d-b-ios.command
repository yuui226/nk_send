#!/usr/bin/env bash
set -Eeuo pipefail

BUILD_STARTED_AT=$SECONDS
STAGE_STARTED_AT=$SECONDS
report_stage() {
  printf '%s: %ss\n' "$1" "$((SECONDS - STAGE_STARTED_AT))"
  STAGE_STARTED_AT=$SECONDS
}

# Finder-launched .command files close only after a successful build. Any
# failure leaves the terminal open so the complete diagnostic remains visible.
finish_terminal() {
  local status=$?
  trap - EXIT
  if [[ "$status" -ne 0 ]]; then
    printf '\n iOS Debug build or installation failed (exit %s); this window will stay open.\n' "$status" >&2
    if [[ -t 0 ]]; then
      read -r -p 'Press Enter to close this window...' _ || true
    fi
  elif [[ "${TERM_PROGRAM:-}" == "Apple_Terminal" ]] && command -v osascript >/dev/null 2>&1; then
    # Finder-launched .command scripts run in a temporary Terminal window.
    # Close only that frontmost Terminal window after a successful build.
    osascript -e 'tell application "Terminal" to close front window' >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap finish_terminal EXIT

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# The packaging directory lives under ios/; resolve the repository root from it.
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
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
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required for USB/Wi-Fi device discovery and installation." >&2
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

report_stage "Device build"
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
(cd "$DERIVED_DATA" && /usr/bin/zip -1qry "$IPA_ARTIFACT" Payload)
/usr/bin/unzip -tqq "$IPA_ARTIFACT"
echo "APP: $APP_ARTIFACT"
echo "IPA: $IPA_ARTIFACT"
report_stage "Signature verification and packaging"

# Match dist-debug/build.command: prune old deliverables only after this
# build's package passes validation. Keep the current APP/IPA pair for device
# installation and sharing; never touch unrelated files or release outputs.
shopt -s nullglob
for OLD_ARTIFACT in "$SCRIPT_DIR"/ZTransfer-ios-debug-*.app "$SCRIPT_DIR"/ZTransfer-ios-debug-*.ipa; do
  [[ "$OLD_ARTIFACT" == "$APP_ARTIFACT" || "$OLD_ARTIFACT" == "$IPA_ARTIFACT" ]] && continue
  rm -rf -- "$OLD_ARTIFACT"
  printf 'Removed old Debug artifact: %s\n' "$(basename -- "$OLD_ARTIFACT")"
done
shopt -u nullglob

# Install the signed device app before optional simulator work. A simulator
# failure must not prevent a connected iPhone from receiving the new build.
INSTALL_STATUS=0
python3 "$PROJECT_ROOT/ios/scripts/install_debug_devices.py" \
  --app "$APP_ARTIFACT" --bundle-id "$BUNDLE_ID" --device "${IOS_DEVICE_ID:-}" \
  || INSTALL_STATUS=$?

report_stage "Device discovery and installation"

# Only when explicitly requested, build the simulator slice,
# reinstall over the existing app, and launch it. The device archive above is
# not installable on a simulator, so this is a separate simulator build.
SIMCTL="$(command -v xcrun || true)"
if [[ -n "$SIMCTL" && "${IOS_BUILD_SIMULATOR:-0}" == "1" && "${IOS_SKIP_SIMULATOR:-0}" != "1" ]]; then
  BOOTED_SIM_IDS="$(xcrun simctl list devices booted 2>/dev/null | sed -nE 's/.*\(([A-F0-9-]+)\) \(Booted\).*/\1/p')"
  if [[ -n "$BOOTED_SIM_IDS" ]]; then
    SIM_DERIVED_DATA="$DERIVED_DATA-simulator"
    echo "Booted simulator(s) detected; building simulator app..."
    SIM_BUILD_ARGS=(-project "$PROJECT_ROOT/ios/ZTransfer.xcodeproj" -scheme ZTransfer
      -configuration Debug -destination "generic/platform=iOS Simulator"
      -derivedDataPath "$SIM_DERIVED_DATA" CODE_SIGNING_ALLOWED=NO build)
    xcodebuild "${SIM_BUILD_ARGS[@]}"
    SIM_APP_PATH="$SIM_DERIVED_DATA/Build/Products/Debug-iphonesimulator/ZTransfer.app"
    while IFS= read -r BOOTED_SIM_ID; do
      [[ -z "$BOOTED_SIM_ID" ]] && continue
      xcrun simctl install "$BOOTED_SIM_ID" "$SIM_APP_PATH"
      xcrun simctl launch "$BOOTED_SIM_ID" "$BUNDLE_ID"
      echo "Installed and launched ZTransfer on simulator $BOOTED_SIM_ID."
    done <<< "$BOOTED_SIM_IDS"
  fi
fi

if [[ "$INSTALL_STATUS" -ne 0 ]]; then
  echo "iOS Debug package is ready, but device installation or launch failed." >&2
  exit "$INSTALL_STATUS"
fi
printf "iOS Debug build complete. Total: %ss\n" "$((SECONDS - BUILD_STARTED_AT))"
