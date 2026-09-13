#!/bin/bash
# Validate production CoreText layout on macOS without building/signing the App.
set -euo pipefail
IOS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ztransfer-frame-text.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
PLATFORM="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer"
BUNDLE="$TEST_DIR/FrameTextTests.xctest"
mkdir -p "$BUNDLE/Contents/MacOS"
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>FrameTextTests</string><key>CFBundleIdentifier</key><string>com.ztransfer.frame-text-tests</string></dict></plist>
PLIST
xcrun swiftc -emit-library -module-name FrameTextTests -D FRAME_TEXT_STANDALONE \
  -F "$PLATFORM/Library/Frameworks" -I "$PLATFORM/usr/lib" -L "$PLATFORM/usr/lib" \
  -Xlinker -rpath -Xlinker "$PLATFORM/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$PLATFORM/usr/lib" \
  "$IOS_ROOT/ZTransfer/Domain/PhotoFrameTextLayout.swift" \
  "$IOS_ROOT/EffectsTests/PhotoFrameTextLayoutTests.swift" \
  -o "$BUNDLE/Contents/MacOS/FrameTextTests"
xcrun xctest "$BUNDLE"
