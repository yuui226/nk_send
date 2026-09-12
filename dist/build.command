#!/usr/bin/env bash
set -Eeuo pipefail

# Finder-launched .command files should disappear after a successful build, while
# failures must leave the terminal open so the error can be read and copied.
finish_terminal() {
  local status=$?
  trap - EXIT
  if [[ "$status" -ne 0 ]]; then
    printf '\nBuild failed (exit %s). The window will stay open.\n' "$status" >&2
    if [[ -t 0 ]]; then
      read -r -p 'Press Enter to close this window...' _ || true
    fi
  fi
  exit "$status"
}
trap finish_terminal EXIT

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# Release must never silently fall back to the debug key.
KEYSTORE_PROPS="$ROOT_DIR/keystore.properties"
if [[ ! -f "$KEYSTORE_PROPS" ]]; then
  cat >&2 <<'MSG'
ERROR: keystore.properties not found; refusing to build a debug-signed release.
Create it in the project root with:
  storeFile=/absolute/path/to/ztransfer-release.jks
  storePassword=<keystore password>
  keyAlias=ztransfer
  keyPassword=<keystore password>
MSG
  exit 1
fi

STORE_FILE="$(awk -F= '$1 == "storeFile" { sub(/^[^=]*=/, ""); print; exit }' "$KEYSTORE_PROPS")"
if [[ -z "$STORE_FILE" ]]; then
  echo "ERROR: storeFile is missing in $KEYSTORE_PROPS" >&2
  exit 1
fi
if [[ "$STORE_FILE" != /* ]]; then
  STORE_FILE="$ROOT_DIR/$STORE_FILE"
fi
if [[ ! -f "$STORE_FILE" ]]; then
  echo "ERROR: signing keystore not found: $STORE_FILE" >&2
  exit 1
fi

# The Android module is compiled for Java 17. Prefer an explicitly configured JDK,
# then the macOS java_home selector, then Homebrew's stable JDK 17 installation.
if [[ -z "${JAVA_HOME:-}" ]]; then
  if JAVA_HOME_CANDIDATE="$(/usr/libexec/java_home -v 17 2>/dev/null)"; then
    export JAVA_HOME="$JAVA_HOME_CANDIDATE"
  elif [[ -d /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ]]; then
    export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
  elif [[ -d /usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ]]; then
    export JAVA_HOME=/usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
  fi
fi
if [[ -z "${JAVA_HOME:-}" || ! -x "$JAVA_HOME/bin/java" ]]; then
  echo "ERROR: JDK 17 is required. Install it with: brew install openjdk@17" >&2
  exit 1
fi
export PATH="$JAVA_HOME/bin:$PATH"

# Resolve the SDK installed by Android Studio or Homebrew command-line tools.
if [[ -z "${ANDROID_SDK_ROOT:-}" ]]; then
  if [[ -n "${ANDROID_HOME:-}" ]]; then
    export ANDROID_SDK_ROOT="$ANDROID_HOME"
  elif [[ -d /opt/homebrew/share/android-commandlinetools ]]; then
    export ANDROID_SDK_ROOT=/opt/homebrew/share/android-commandlinetools
  elif [[ -d "$HOME/Library/Android/sdk" ]]; then
    export ANDROID_SDK_ROOT="$HOME/Library/Android/sdk"
  fi
fi
if [[ -z "${ANDROID_SDK_ROOT:-}" || ! -d "$ANDROID_SDK_ROOT/platforms/android-35" ]]; then
  echo "ERROR: Android SDK platform 35 is required." >&2
  echo "Install with: sdkmanager 'platforms;android-35' 'build-tools;35.0.0' 'platform-tools'" >&2
  exit 1
fi
export ANDROID_HOME="$ANDROID_SDK_ROOT"

if [[ ! -x "$ROOT_DIR/gradlew" ]]; then
  echo "ERROR: gradlew is missing or not executable." >&2
  exit 1
fi

KIND="apk"
TASK=":app:assembleRelease"
SOURCE="$ROOT_DIR/app/build/outputs/apk/release/app-release.apk"
if [[ "${1:-}" == "aab" ]]; then
  KIND="aab"
  TASK=":app:bundleRelease"
  SOURCE="$ROOT_DIR/app/build/outputs/bundle/release/app-release.aab"
elif [[ -n "${1:-}" ]]; then
  echo "Usage: $0 [aab]" >&2
  exit 2
fi

VERSION_NAME="$(sed -nE 's/^[[:space:]]*versionName[[:space:]]*=[[:space:]]*"([^"]+)".*$/\1/p' app/build.gradle.kts | head -n 1)"
if [[ -z "$VERSION_NAME" ]]; then
  echo "ERROR: versionName not found in app/build.gradle.kts" >&2
  exit 1
fi

printf 'Building signed release %s (%s) with %s...\n' "$KIND" "$TASK" "$JAVA_HOME"
"$ROOT_DIR/gradlew" "$TASK" --no-daemon --console=plain

if [[ ! -f "$SOURCE" ]]; then
  echo "ERROR: release artifact not found: $SOURCE" >&2
  exit 1
fi

STAMP="$(date '+%y%m%d%H%M')"
BASENAME="ZTransfer-${VERSION_NAME}-${STAMP}"
DEST="$SCRIPT_DIR/$BASENAME.$KIND"
cp -f "$SOURCE" "$DEST"
printf 'Artifact copied to: %s\n' "$DEST"

MAPPING="$ROOT_DIR/app/build/outputs/mapping/release/mapping.txt"
if [[ -f "$MAPPING" ]]; then
  cp -f "$MAPPING" "$SCRIPT_DIR/$BASENAME.mapping.txt"
  printf 'Mapping copied to:  %s\n' "$SCRIPT_DIR/$BASENAME.mapping.txt"
fi

# If an authorized Android device is connected, install the freshly copied release APK.
# AAB files are for Play upload and cannot be installed with adb.
if [[ "$KIND" != "apk" ]]; then
  echo "AAB built; skipping device installation."
  exit 0
fi
# This is intentionally best-effort for a build-only Mac workflow: no device means no install.
ADB="$(command -v adb || true)"
if [[ -z "$ADB" ]]; then
  echo "ADB not found; skipping device installation."
  exit 0
fi

FOUND_DEVICE=0
while IFS= read -r DEVICE; do
  [[ -z "$DEVICE" ]] && continue
  FOUND_DEVICE=1
  printf 'Installing release APK to %s...\n' "$DEVICE"
  "$ADB" -s "$DEVICE" install -r "$DEST"
  printf 'Launching ZTransfer release on %s...\n' "$DEVICE"
  "$ADB" -s "$DEVICE" shell am start -n com.ztransfer/.MainActivity
done < <("$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1 }')
if [[ "$FOUND_DEVICE" == 0 ]]; then
  echo "No authorized ADB device connected; skipping device installation."
fi
