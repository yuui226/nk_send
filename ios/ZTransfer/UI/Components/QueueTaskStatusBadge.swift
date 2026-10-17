import SwiftUI
import UIKit

/// TransferScreen.TaskStatusBadge + Compose 1.7.6 Crossfade/Transition.
/// The pop restarts without velocity; interrupted alpha channels retain theirs.
struct QueueBadgeMotion {
    struct Layer: Identifiable {
        let state: TransferCardVisualState
        var alpha: ZTransferScalarAnimation
        var id: TransferCardVisualState { state }
    }

    private(set) var state: TransferCardVisualState
    private(set) var scale = ZTransferScalarAnimation(value: 1)
    private(set) var layers: [Layer]
    private var fadeFrame: Int64?
    var isRunning: Bool { scale.isRunning || layers.contains { $0.alpha.isRunning } }

    init(state: TransferCardVisualState) {
        self.state = state
        layers = [.init(state: state, alpha: .init(value: 1, retainsEndVelocity: true))]
    }

    mutating func update(_ next: TransferCardVisualState) {
        guard next != state else { return }
        state = next
        scale.reset(to: 0.62)
        scale.retarget(1, using: .bouncy)

        if !layers.contains(where: { $0.state == next }) {
            layers.append(.init(state: next, alpha: .init(value: 0, retainsEndVelocity: true)))
        }
        for index in layers.indices {
            let target: Float = layers[index].state == next ? 1 : 0
            // Transition.updateTarget calls resetAnimations for EVERY channel,
            // including those whose numeric target is unchanged. An unfinished
            // tween therefore restarts as the default Float spring (1500, .01).
            let interrupted = layers[index].alpha.isRunning
            layers[index].alpha.retarget(target,
                using: interrupted ? .criticallyDampedSpring(stiffness: 1500) : .tween(milliseconds: 180),
                force: true, atFrameNanos: fadeFrame)
        }
    }

    mutating func advance(_ nanos: Int64) {
        scale.advance(frameNanos: nanos)
        for index in layers.indices { layers[index].alpha.advance(frameNanos: nanos) }
        if layers.contains(where: { $0.alpha.isRunning }) {
            fadeFrame = nanos
        } else {
            // Crossfade retains every intermediate key until all alpha channels
            // finish, independently of the outer badge's longer pop animation.
            layers.removeAll { $0.state != state }
            fadeFrame = nil
        }
    }
}

@MainActor
private final class QueueBadgeAnimator: NSObject, ObservableObject {
    @Published private(set) var motion: QueueBadgeMotion
    private var link: CADisplayLink?
    init(state: TransferCardVisualState) { motion = .init(state: state) }

    func mount(_ state: TransferCardVisualState) {
        stop()
        motion = .init(state: state)
    }

    func update(_ state: TransferCardVisualState) {
        motion.update(state)
        guard motion.isRunning, link == nil else { return }
        let link = CADisplayLink(target: FrameTarget(owner: self), selector: #selector(FrameTarget.frame(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    private func advance(_ link: CADisplayLink) {
        motion.advance(Int64(link.timestamp * 1_000_000_000))
        if !motion.isRunning { stop() }
    }

    func stop() { link?.invalidate(); link = nil }

    // CADisplayLink retains its target; the proxy prevents retaining a removed badge.
    @MainActor private final class FrameTarget: NSObject {
        weak var owner: QueueBadgeAnimator?
        init(owner: QueueBadgeAnimator) { self.owner = owner }
        @objc func frame(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.advance(link)
        }
    }
}

struct QueueTaskStatusBadge: View {
    let item: TransferQueueItem
    @StateObject private var animator: QueueBadgeAnimator
    private var state: TransferCardVisualState { .init(item: item) }

    init(item: TransferQueueItem) {
        self.item = item
        _animator = StateObject(wrappedValue: QueueBadgeAnimator(state: .init(item: item)))
    }

    var body: some View {
        ZStack {
            ForEach(animator.motion.layers) { layer in
                QueueBadgeIcon(state: layer.state)
                    .frame(width: 13, height: 13)
                    .foregroundStyle(ZTransferColors.onAccent)
                    .opacity(Double(layer.alpha.value))
            }
        }
        .frame(width: 22, height: 22)
        .background(state.color, in: Circle())
        .overlay(Circle().strokeBorder(ZTransferColors.surface, lineWidth: 2))
        .scaleEffect(CGFloat(animator.motion.scale.value))
        .transaction { $0.animation = nil }
        .accessibilityHidden(true)
        .onAppear { animator.mount(state) }
        .onChange(of: state) { animator.update($0) }
        .onChange(of: item.id) { _ in animator.mount(state) }
        .onDisappear { animator.stop() }
    }
}
