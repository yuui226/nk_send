#!/usr/bin/env bash
# Focused kernel verification only; no Gradle, Android packaging or device mutation.
set -euo pipefail
cd "$(dirname "$0")/.."
grain_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ztransfer-grain.XXXXXX")
trap 'rm -rf -- "$grain_test_dir"' EXIT
"${CXX:-clang++}" -std=c++17 -O2 -ffp-contract=off -fno-fast-math -fwrapv \
  -Wall -Wextra -Werror -Iapp/src/main/cpp \
  tools/tests/photo_grain_host.cpp -o "$grain_test_dir/photo-grain-test"
"$grain_test_dir/photo-grain-test"
if [[ -n "${JAVA_HOME:-}" ]]; then
  case "$(uname -s)" in
    Darwin) grain_platform=darwin; grain_library=libphoto_grain.dylib; grain_shared=-dynamiclib ;;
    Linux) grain_platform=linux; grain_library=libphoto_grain.so; grain_shared=-shared ;;
    *) echo 'JNI host checks require macOS or Linux.' >&2; exit 1 ;;
  esac
  "${CXX:-clang++}" -std=c++17 -O2 -ffp-contract=off -fno-fast-math -fwrapv \
    -fno-exceptions -fno-rtti -fPIC "$grain_shared" \
    -I"$JAVA_HOME/include" -I"$JAVA_HOME/include/$grain_platform" \
    app/src/main/cpp/photo_grain.cpp -o "$grain_test_dir/$grain_library"
  "$JAVA_HOME/bin/javac" -d "$grain_test_dir" tools/tests/PhotoGrainJniTest.java
  "$JAVA_HOME/bin/java" -Djava.awt.headless=true -cp "$grain_test_dir" \
    com.ztransfer.grain.PhotoGrainJniTest "$grain_test_dir/$grain_library" "$@"
else
  echo 'JAVA_HOME unset: standalone kernel checks passed; JNI checks skipped.'
fi
