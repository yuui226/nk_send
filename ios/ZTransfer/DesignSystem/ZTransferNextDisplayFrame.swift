import UIKit

/// The equivalent of withFrameNanos for accepted image transitions. Yielding a
/// Task can resume in the same UI transaction and skip the transparent frame.
@MainActor
final class ZTransferNextDisplayFrame {
    private var link: CADisplayLink?
    private var continuation: CheckedContinuation<Void, Error>?

    static func wait() async throws {
        let frame = ZTransferNextDisplayFrame()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                frame.continuation = continuation
                let link = ZTransferDisplayLink.make(owner: frame) { owner, _ in owner.finish() }
                frame.link = link
                link.add(to: .main, forMode: .common)
            }
        } onCancel: {
            Task { @MainActor in frame.finish(error: CancellationError()) }
        }
    }

    private func finish(error: Error? = nil) {
        link?.invalidate(); link = nil
        let pending = continuation; continuation = nil
        if let error { pending?.resume(throwing: error) }
        else { pending?.resume() }
    }
}
