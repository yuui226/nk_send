#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
sta_test_work="$(mktemp -d /tmp/ztransfer-sta-parity.XXXXXX)"
sta_test_platform="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer"
sta_test_bundle="$sta_test_work/STATransferTests.xctest"
mkdir -p "$sta_test_bundle/Contents/MacOS"
cp tools/sta-transfer-tests/Info.plist "$sta_test_bundle/Contents/Info.plist"
# Mechanically extract Foundation-only production declarations. No rewritten
# policy/writer, fake repository, simulator, or app installation is involved.
ruby - "$sta_test_work" <<'RUBY'
def section(path, first, last)
  text = File.read(path)
  start = text.index(first) or abort "Missing #{first} in #{path}"
  stop = last ? (text.index(last, start + first.length) or abort "Missing #{last}") : text.length
  text[start...stop]
end
root = ARGV.fetch(0)
parts = ["import Foundation\nimport Darwin\n"]
parts << section("ios/ZTransfer/Domain/CameraRepository.swift", "let transferChunkSize:", "func transferUniqueOutputURL(")
parts << section("ios/ZTransfer/Domain/CameraRepository.swift", "let transferResumeChunkSize:", "func transferPartialFileName(")
parts << section("ios/ZTransfer/Domain/TransferQueue.swift", "internal func endToEndBytesPerSecond(", "/// The queue only needs")
parts << section("ios/ZTransfer/Domain/CameraDownload.swift", "let cameraExifHeaderCaptureBytes", "extension PhotoFrameMetadata {")
parts << section("ios/ZTransfer/Domain/CameraDownload.swift", "enum CameraDownloadError:", nil)
parts << section("ios/ZTransfer/App/RootView.swift", "enum AppLocalized {", "struct RootView:")
File.write(File.join(root, "ProductionDeclarations.swift"), parts.join("\n"))
gate = File.read("ios/ZTransferTests/CameraIOGateTests.swift").sub("@testable import ZTransfer", "")
# Only this test needs the UIKit-backed full repository, not CameraIOGate.
first = gate.index("    func testEffectPreviewWaitsForEveryForegroundOwnerAndReleasesFillGate()") or abort "Missing repository test"
last = gate.index("    func testReservationDoesNotBlockOrdinaryOrIdleCommandsBetweenFHDAndExif()", first) or abort "Missing gate boundary"
gate[first...last] = ""
File.write(File.join(root, "CameraIOGateTests.swift"), gate)
RUBY
xcrun swiftc -emit-library -module-name STATransferTests -swift-version 6 -D STA_GATE_HANDOFF_TESTING \
  -F "$sta_test_platform/Library/Frameworks" -I "$sta_test_platform/usr/lib" -L "$sta_test_platform/usr/lib" \
  -Xlinker -rpath -Xlinker "$sta_test_platform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$sta_test_platform/usr/lib" \
  ios/ZTransfer/Transport/PTP/*.swift \
  ios/ZTransfer/Domain/CameraIOGate.swift \
  ios/ZTransfer/App/AndroidLocalization.swift ios/ZTransfer/App/IOSLocalization.swift \
  "$sta_test_work/ProductionDeclarations.swift" "$sta_test_work/CameraIOGateTests.swift" \
  tools/sta-transfer-tests/STAAndroidTransferParityTests.swift \
  tools/sta-transfer-tests/CameraIOGateHandoffTests.swift \
  -o "$sta_test_bundle/Contents/MacOS/STATransferTests"
xcrun xctest "$sta_test_bundle"
