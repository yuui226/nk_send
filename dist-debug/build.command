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

# The Android module targets Java 17. Prefer an explicitly configured JDK,
# then the macOS selector, then Homebrew's stable JDK 17 installation.
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

printf 'Building timestamped Debug APK with %s...\n' "$JAVA_HOME"
"$ROOT_DIR/gradlew" :app:assembleDebug --no-daemon --console=plain

# app/build.gradle.kts finalizes assembleDebug with copyTimestampedDebugApk,
# which creates the distributable name in this directory.
DEBUG_APK="$(ls -t "$SCRIPT_DIR"/ZTransfer-debug-*.apk 2>/dev/null | head -n 1 || true)"
if [[ -z "$DEBUG_APK" || ! -f "$DEBUG_APK" ]]; then
  echo "ERROR: timestamped Debug APK was not found in $SCRIPT_DIR" >&2
  exit 1
fi
printf 'Artifact ready: %s\n' "$DEBUG_APK"

# Match dist-debug/build-debug.bat: install and launch every authorized ADB device,
# while allowing a disconnected-phone build to finish successfully.
ADB="$(command -v adb || true)"
if [[ -z "$ADB" ]]; then
  echo "ADB not found; skipping device installation."
  exit 0
fi

FOUND_DEVICE=0
while IFS= read -r DEVICE; do
  [[ -z "$DEVICE" ]] && continue
  FOUND_DEVICE=1
  printf 'Installing to %s...\n' "$DEVICE"
  "$ADB" -s "$DEVICE" install -r "$DEBUG_APK"
  printf 'Launching ZTransfer on %s...\n' "$DEVICE"
  "$ADB" -s "$DEVICE" shell am start -n com.ztransfer.debug/com.ztransfer.MainActivity
done < <("$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1 }')
if [[ "$FOUND_DEVICE" == 0 ]]; then
  echo "No authorized ADB device connected; skipping device installation."
fi
