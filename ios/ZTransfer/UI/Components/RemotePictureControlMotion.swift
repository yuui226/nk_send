import SwiftUI
import UIKit

struct RemotePictureControlPage: Hashable {
    enum Confirmation: Hashable { case clear, folder }
    var slot: Int?
    var confirmation: Confirmation?
    static let slots = Self()
}

/// RemotePictureControlPanel.kt AnimatedContent: 180/40ms in, 140ms out,
/// IntSize spring 400/.85. Retain outgoing content and block taps until all
/// channels settle; a weak display target stops as soon as it is idle.
@MainActor final class RemotePictureControlMotion: ObservableObject {
    @Published private(set) var revision = 0
    private(set) var page: RemotePictureControlPage = .slots
    struct Exit: Identifiable {
        let page: RemotePictureControlPage
        let size: CGSize
        fileprivate var alpha: ZTransferScalarAnimation
        var id: RemotePictureControlPage { page }
        var opacity: Double { Double(alpha.value) }
    }
    private(set) var exits: [Exit] = []
    var outgoing: RemotePictureControlPage? { exits.first?.page }
    private(set) var size: CGSize = .zero
    private(set) var targetSize: CGSize = .zero
    private(set) var ready = false
    private var width = ZTransferScalarAnimation(value: 0)
    private var height = ZTransferScalarAnimation(value: 0)
    private var incomingAlpha = ZTransferScalarAnimation(value: 1)
    private var scale: CGFloat = 1
    private var link: CADisplayLink?
    var settled: Bool { ready && !width.isRunning && !height.isRunning && !incomingAlpha.isRunning && exits.isEmpty }
    var incomingOpacity: Double { Double(incomingAlpha.value) }
    var outgoingOpacity: Double { exits.first?.opacity ?? 0 }
    var clockRunning: Bool { link != nil }
    func configure(page next: RemotePictureControlPage, size nextSize: CGSize, scale: CGFloat) {
        let scale = max(1, scale)
        guard !ready || next != page || nextSize != targetSize || scale != self.scale else { return }
        self.scale = scale
        if !ready {
            page = next; ready = true; size = nextSize; targetSize = nextSize
            width.reset(to: Float(nextSize.width * scale)); height.reset(to: Float(nextSize.height * scale))
        } else {
            if page != next {
                // A fast camera write can finish during confirmation -> editor.
                // AnimatedContent retains *each* exiting page, including that
                // earlier confirmation, rather than flashing it away.
                let returning = exits.first { $0.page == next }
                exits.removeAll { $0.page == next }
                var leaving = incomingAlpha
                leaving.retarget(0, using: .tween(milliseconds: 140))
                exits.append(Exit(page: page, size: targetSize, alpha: leaving))
                page = next
                incomingAlpha = returning?.alpha ?? ZTransferScalarAnimation(value: 0)
                incomingAlpha.retarget(1, using: .tween(milliseconds: 180, delayMilliseconds: 40))
            }
            targetSize = nextSize
            let spring = ZTransferAndroidMotion.underdampedSpring(stiffness: 400, dampingRatio: 0.85, threshold: 1)
            width.retarget(Float(nextSize.width * scale), using: spring, fromDisplayedValue: width.value.rounded())
            height.retarget(Float(nextSize.height * scale), using: spring, fromDisplayedValue: height.value.rounded())
            if !settled && link == nil {
                link = ZTransferDisplayLink.make(owner: self) { $0.advance(Int64($1.timestamp * 1_000_000_000)) }
                link?.add(to: .main, forMode: .common)
            }
        }
        revision &+= 1
    }
    func advance(_ nanos: Int64) {
        guard !settled else { stop(); return }
        width.advance(frameNanos: nanos); height.advance(frameNanos: nanos)
        incomingAlpha.advance(frameNanos: nanos)
        for index in exits.indices { exits[index].alpha.advance(frameNanos: nanos) }
        exits.removeAll { !$0.alpha.isRunning && $0.alpha.value == 0 }
        size = CGSize(width: CGFloat(width.value.rounded()) / scale, height: CGFloat(height.value.rounded()) / scale)
        if settled { stop() }
        revision &+= 1
    }
    func stop() { link?.invalidate(); link = nil }
}
