#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work="$(mktemp -d /tmp/ztransfer-photo-loading.XXXXXX)"
platform="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer"
bundle="$work/PhotoLoadingTests.xctest"
mkdir -p "$bundle/Contents/MacOS"
cp tools/photo-loading-tests/Info.plist "$bundle/Contents/Info.plist"
# Compile the actual date-range declarations, not a handwritten test double.
# The rest of PhotoFilter depends on UIKit's transfer queue and is not under
# this host-only test. Fail if the declaration boundaries change.
ruby -e '
  source = File.read("ios/ZTransfer/Domain/PhotoFilter.swift")
  stop = source.index("func restoredPhotoDateRange(") or abort "Missing date-range boundary"
  section = source[0...stop]
  abort "Missing declarations" unless section.include?("struct PhotoDateRange:") && section.include?("func validPhotoCaptureDay(")
  File.write(ARGV[0], section)
' "$work/PhotoDateRange.swift"
xcrun swiftc -emit-library -module-name PhotoLoadingTests \
  -D THUMBNAIL_CACHE_STANDALONE -swift-version 6 \
  -F "$platform/Library/Frameworks" -I "$platform/usr/lib" -L "$platform/usr/lib" \
  -Xlinker -rpath -Xlinker "$platform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$platform/usr/lib" \
  ios/ZTransfer/Transport/PTP/*.swift \
  ios/ZTransfer/Domain/PhotoThumbnailStore.swift \
  ios/ZTransfer/Domain/PhotoThumbnailDiskCache.swift \
  ios/ZTransfer/Domain/PhotoThumbnailFillQueue.swift \
  "$work/PhotoDateRange.swift" \
  ios/ZTransferTests/PhotoThumbnailStoreTests.swift \
  ios/ZTransferTests/PhotoThumbnailDiskCacheTests.swift \
  -o "$bundle/Contents/MacOS/PhotoLoadingTests"
xcrun xctest "$bundle"
