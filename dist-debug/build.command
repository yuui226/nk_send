#!/usr/bin/env bash
set -Eeuo pipefail
BUILD_LOG=""

# Finder-launched .command files should disappear after a successful build, while
# failures must leave the terminal open so the error can be read and copied.
finish_terminal() {
  local status=$?
  trap - EXIT
  if [[ -n "${BUILD_LOG:-}" ]]; then rm -f -- "$BUILD_LOG"; fi
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
BUILD_LOG="$(mktemp "${TMPDIR:-/tmp}/ztransfer-debug-build.XXXXXX")"
"$ROOT_DIR/gradlew" :app:assembleDebug --no-daemon --console=plain | tee "$BUILD_LOG"

# app/build.gradle.kts finalizes assembleDebug with copyTimestampedDebugApk,
# which creates the distributable name in this directory.
# Use the artifact reported by THIS successful build, never an older file from ls.
DEBUG_APK="$(sed -n 's/^Timestamped debug APK: //p' "$BUILD_LOG" | tail -n 1)"
if [[ -z "$DEBUG_APK" || ! -s "$DEBUG_APK" ||
      "$(dirname -- "$DEBUG_APK")" != "$SCRIPT_DIR" ||
      "$(basename -- "$DEBUG_APK")" != ZTransfer-debug-*.apk ]]; then
  echo "ERROR: this build did not report a valid timestamped Debug APK in $SCRIPT_DIR" >&2
  exit 1
fi
printf 'Artifact ready: %s\n' "$DEBUG_APK"

# Only clean this script's directory after a successful build and artifact validation.
# Include hidden APK files; do not recurse or touch the release directory.
shopt -s nullglob dotglob nocaseglob
for OLD_APK in "$SCRIPT_DIR"/*.apk; do
  [[ "$OLD_APK" == "$DEBUG_APK" || ! -f "$OLD_APK" ]] && continue
  rm -- "$OLD_APK"
  printf 'Removed old APK: %s\n' "$(basename -- "$OLD_APK")"
done
shopt -u nullglob dotglob nocaseglob

# Store a file reference, not its path as text, so Finder/chat apps can paste the APK.
if /usr/bin/osascript -l JavaScript - "$DEBUG_APK" <<'JAVASCRIPT'
ObjC.import('AppKit');
function run(argv) {
  var path = argv[0];
  var url = $.NSURL.fileURLWithPath(path);
  var board = $.NSPasteboard.generalPasteboard;
  board.clearContents;
  if (!board.writeObjects($.NSArray.arrayWithObject(url))) {
    throw new Error('Cannot write APK file URL to clipboard');
  }
  // Older file-aware apps use the legacy filenames list instead of public.file-url.
  board.setPropertyListForType($.NSArray.arrayWithObject($(path)), $('NSFilenamesPboardType'));
  var stored = board.stringForType($('public.file-url'));
  if (!stored || ObjC.unwrap(stored) !== ObjC.unwrap(url.absoluteString)) {
    throw new Error('Clipboard file URL verification failed');
  }
}
JAVASCRIPT
then
  echo "APK file copied to clipboard. Paste with Command-V."
else
  echo "WARNING: APK built successfully, but copying the file to the clipboard failed." >&2
  echo "You can copy the APK manually from: $DEBUG_APK" >&2
fi

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
