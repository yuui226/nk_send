#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
ORACLE_JAVA="${NEF_EXIF_JAVA:-/opt/homebrew/opt/openjdk@17/bin/java}"
ORACLE_JAVAC="$(dirname -- "$ORACLE_JAVA")/javac"
if [[ ! -x "$ORACLE_JAVA" || ! -x "$ORACLE_JAVAC" ]]; then
    echo 'Set NEF_EXIF_JAVA to the java executable of a local JDK (17+).' >&2
    exit 1
fi
ORACLE_WORK="$(mktemp -d /tmp/ztransfer-nef-oracle.XXXXXX)"
# Deliberately retain dependencies/output for inspection, never touch app caches.
echo "Oracle workspace: $ORACLE_WORK"
curl -fsSL 'https://dl.google.com/dl/android/maven2/androidx/exifinterface/exifinterface/1.3.7/exifinterface-1.3.7.aar' -o "$ORACLE_WORK/exif.aar"
curl -fsSL 'https://repo.maven.apache.org/maven2/com/google/android/android/4.1.1.4/android-4.1.1.4.jar' -o "$ORACLE_WORK/android.jar"
unzip -q "$ORACLE_WORK/exif.aar" classes.jar -d "$ORACLE_WORK"
"$ORACLE_JAVAC" -cp "$ORACLE_WORK/android.jar:$ORACLE_WORK/classes.jar" -d "$ORACLE_WORK/bin" \
    "$SCRIPT_DIR/Oracle.java" "$SCRIPT_DIR/stubs/android/util/Log.java" \
    "$SCRIPT_DIR/stubs/android/util/Pair.java" "$SCRIPT_DIR/stubs/android/os/Build.java" \
    "$SCRIPT_DIR/stubs/android/media/MediaDataSource.java"
NEF_EXIF_JAVA="$ORACLE_JAVA" \
NEF_EXIF_ORACLE_CLASSPATH="$ORACLE_WORK/bin:$ORACLE_WORK/classes.jar:$ORACLE_WORK/android.jar" \
ZTRANSFER_PROTOCOL_ONLY=1 swift test --package-path "$PROJECT_ROOT/ios" --filter NEFExifParityTests
