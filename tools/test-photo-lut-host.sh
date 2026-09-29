#!/usr/bin/env bash
# Host JNI parity/performance only. Does not package, install or launch Android apps.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${JAVA_HOME:?Set JAVA_HOME to JDK 17}"
work=$(mktemp -d "${TMPDIR:-/tmp}/ztransfer-lut.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
case "$(uname -s)" in
  Darwin) platform=darwin; library=libztransfer_crop.dylib; shared=-dynamiclib ;;
  Linux) platform=linux; library=libztransfer_crop.so; shared=-shared ;;
  *) echo 'This host test requires macOS or Linux.' >&2; exit 1 ;;
esac
clang++ -std=c++17 -O2 -ffp-contract=off -fno-fast-math -fno-exceptions -fno-rtti -fPIC "$shared" \
  -I"$JAVA_HOME/include" -I"$JAVA_HOME/include/$platform" \
  app/src/main/cpp/photo_lut.cpp -o "$work/$library"
cat > "$work/init.gradle" <<'GRADLE'
allprojects {
    tasks.withType(Test).configureEach {
        jvmArgs "-Djava.library.path=${System.getProperty('ztransfer.nativeTestDir')}",
            '-Dztransfer.nativeLutRequired=true'
        testLogging.showStandardStreams = true
    }
}
GRADLE
./gradlew "-Dztransfer.nativeTestDir=$work" -I "$work/init.gradle" :app:testDebugUnitTest \
  --tests 'com.ztransfer.filter.PhotoCube*' --tests 'com.ztransfer.filter.PhotoLutExecutionTest' --console=plain
