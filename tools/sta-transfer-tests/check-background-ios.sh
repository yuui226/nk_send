#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# Typecheck the real UIKit adapter methods without building/installing the App.
# Only the actor's unrelated queue/domain dependencies are replaced by a shell;
# the lifecycle owner and method bodies are extracted unchanged from production.
ruby - <<'RUBY' | xcrun --sdk iphoneos swiftc -typecheck -swift-version 6 -target arm64-apple-ios16.0 -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" -
source = File.read("ios/ZTransfer/Domain/TransferQueue.swift")
def section(source, first, last)
  start = source.index(first) or abort "Missing #{first}"
  stop = source.index(last, start + first.length) or abort "Missing #{last}"
  source[start...stop]
end
puts "import Foundation\nimport UIKit"
puts section(source, "@MainActor\nfinal class TransferBackgroundActivity", "/// The queue only needs")
puts "actor BackgroundQueueAdapterTypecheck {"
puts "private var backgroundActivity: TransferBackgroundActivity<UIBackgroundTaskIdentifier>?"
puts "private var backgroundTaskToken: UUID?"
puts "private var worker: Task<Void, Never>?"
puts section(source, "    private func beginBackgroundTransferActivity()", "    /// Explicitly starting the pending queue")
puts "}"
RUBY
