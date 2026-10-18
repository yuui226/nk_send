import SwiftUI
import UIKit

/// FileListScreen's fadeIn/out + slideIn/outVertically { it / 2 }.
/// Compose uses spring(400) for both, with Float .01 / IntOffset 1 thresholds.
struct PhotoListHintMotion {
    private(set) var visible = false
    private(set) var retained = false
    private(set) var alpha = ZTransferScalarAnimation(value: 0)
    private(set) var offset = ZTransferScalarAnimation(value: 0)
    private var halfHeight: Float = 0
    var isRunning: Bool { alpha.isRunning || offset.isRunning }

    mutating func setVisible(_ next: Bool, height: Int) {
        halfHeight = Float(height / 2)
        guard next != visible else {
            // A replacement can measure a different line count before the
            // first frame. Use that actual height for the initial half-slide.
            if next, alpha.value == 0 {
                offset = .init(value: halfHeight)
                offset.retarget(0, using: .criticallyDampedSpring(stiffness: 400, threshold: 1))
            }
            return
        }
        if next && !retained {
            alpha = .init(value: 0)
            offset = .init(value: halfHeight)
        }
        visible = next
        retained = true
        alpha.retarget(next ? 1 : 0, using: .criticallyDampedSpring(stiffness: 400))
        offset.retarget(next ? 0 : halfHeight,
            using: .criticallyDampedSpring(stiffness: 400, threshold: 1),
            fromDisplayedValue: offset.value.rounded(.toNearestOrAwayFromZero))
    }
    mutating func advance(_ nanos: Int64) {
        alpha.advance(frameNanos: nanos)
        offset.advance(frameNanos: nanos)
        if !visible && !isRunning { retained = false }
    }
}

/// One message and deadline: replacement never resurfaces an earlier message.
@MainActor
final class PhotoListHintState: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var visible = false
    private var deadline: Task<Void, Never>?
    private var generation = 0

    func show(_ text: String, duration: Duration = .milliseconds(1800)) {
        generation &+= 1
        let current = generation
        deadline?.cancel()
        if self.text != text { self.text = text }
        if !visible { visible = true }
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard let self, generation == current else { return }
            visible = false // Keep text for AnimatedVisibility's outgoing content.
            deadline = nil
        }
    }
    func stop() {
        generation &+= 1
        deadline?.cancel()
        deadline = nil
        if visible { visible = false }
    }
    deinit { deadline?.cancel() }
}

@MainActor
final class PhotoListHintAnimator: ObservableObject {
    struct Frame: Equatable {
        var retained = false
        var alpha: Float = 0
        var offset: Float = 0
    }
    private(set) var motion = PhotoListHintMotion()
    @Published private(set) var frame = Frame()
    private var height: Int?
    private var link: CADisplayLink?
    func setVisible(_ visible: Bool, height: Int) {
        if visible != motion.visible || self.height != height {
            self.height = height
            motion.setVisible(visible, height: height)
            publish()
        }
        guard motion.isRunning, link == nil else { return }
        let next = CADisplayLink(target: DisplayLinkTarget(owner: self), selector: #selector(DisplayLinkTarget.frame(_:)))
        link = next
        next.add(to: .main, forMode: .common)
    }
    func advanceFrame(_ nanos: Int64) {
        motion.advance(nanos)
        publish()
        if !motion.isRunning { link?.invalidate(); link = nil }
    }
    private func publish() {
        let next = Frame(retained: motion.retained, alpha: motion.alpha.value,
                         offset: motion.offset.value.rounded(.toNearestOrAwayFromZero))
        if next != frame { frame = next }
    }
    func stop() { link?.invalidate(); link = nil; motion = .init(); height = nil; publish() }

    @MainActor private final class DisplayLinkTarget: NSObject {
        weak var owner: PhotoListHintAnimator?
        init(owner: PhotoListHintAnimator) { self.owner = owner }
        @objc func frame(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.advanceFrame(Int64(link.timestamp * 1_000_000_000))
        }
    }
}

private struct PhotoListHintHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Shared bottom hint host, mounted above the preview by PhotoListView.
/// Surface elevation uses the shared Android shadow; parent fade includes it once.
struct PhotoListHint: View {
    @ObservedObject var state: PhotoListHintState
    @State private var animator = PhotoListHintAnimator()
    @State private var height: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        PhotoListHintPresentation(visible: state.visible, animator: animator) {
            Text(state.text)
                .zTransferTypography(.labelLarge)
                .foregroundStyle(ZTransferColors.primaryText)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(colorScheme == .dark
                    ? Color(white: 30 / 255).opacity(0.92) : Color.white.opacity(0.95),
                    in: RoundedRectangle(cornerRadius: 22, style: .circular))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .circular)
                    .strokeBorder(colorScheme == .dark ? .white.opacity(0.15) : .black.opacity(0.10), lineWidth: 1))
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: PhotoListHintHeight.self, value: proxy.size.height)
                })
                .background(AndroidShadowView(cornerRadius: 22, elevation: 6))
                .accessibilityIdentifier("photo-list-hint")
        }
        .onPreferenceChange(PhotoListHintHeight.self) { next in
            guard next > 0 else { return }
            if height != next { height = next }
            animator.setVisible(state.visible, height: Int((next * displayScale).rounded()))
        }
        .onChange(of: state.visible) { visible in
            if height > 0 { animator.setVisible(visible, height: Int((height * displayScale).rounded())) }
        }
        .onDisappear { animator.stop() }
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
    }
}

/// Keep text, measurement and shadow content stable while only the fade/slide
/// placement consumes display frames. Entry still mounts before measurement.
struct PhotoListHintPresentation<Content: View>: View {
    let visible: Bool
    @ObservedObject var animator: PhotoListHintAnimator
    @ViewBuilder let content: Content
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        if visible || animator.frame.retained {
            content.opacity(Double(animator.frame.alpha))
                .offset(y: CGFloat(animator.frame.offset) / displayScale)
        }
    }
}
