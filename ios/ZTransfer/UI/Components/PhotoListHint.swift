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
        self.text = text
        visible = true
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
        visible = false
    }
    deinit { deadline?.cancel() }
}

@MainActor
private final class PhotoListHintAnimator: NSObject, ObservableObject {
    @Published private(set) var motion = PhotoListHintMotion()
    private var link: CADisplayLink?
    func setVisible(_ visible: Bool, height: Int) {
        motion.setVisible(visible, height: height)
        guard motion.isRunning, link == nil else { return }
        let next = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link = next
        next.add(to: .main, forMode: .common)
    }
    @objc private func frame(_ sender: CADisplayLink) {
        motion.advance(Int64(sender.timestamp * 1_000_000_000))
        if !motion.isRunning { link?.invalidate(); link = nil }
    }
    func stop() { link?.invalidate(); link = nil; motion = .init() }
}

private struct PhotoListHintHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Shared bottom hint host, mounted above the preview by PhotoListView.
/// Surface elevation uses the shared Android shadow; parent fade includes it once.
struct PhotoListHint: View {
    @ObservedObject var state: PhotoListHintState
    @StateObject private var animator = PhotoListHintAnimator()
    @State private var height: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if state.visible || animator.motion.retained {
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
                    .opacity(Double(animator.motion.alpha.value))
                    .offset(y: CGFloat(animator.motion.offset.value.rounded(.toNearestOrAwayFromZero)) / displayScale)
                    .accessibilityIdentifier("photo-list-hint")
            }
        }
        .onPreferenceChange(PhotoListHintHeight.self) { next in
            guard next > 0 else { return }
            height = next
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
