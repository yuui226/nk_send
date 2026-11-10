import SwiftUI
import UIKit

@MainActor
final class QueueNumericValueClock: ObservableObject {
    @Published private(set) var motion: QueueNumericValueMotion
    private var scale: CGFloat = 1
    private var mounted = true
    private let automaticFrames: Bool
    private var link: CADisplayLink?
    var clockRunning: Bool { link != nil }

    init(text: String, value: Int64, height: CGFloat, automaticFrames: Bool = true) {
        motion = .init(text: text, value: value, heightPixels: Int(floor(height + 0.5)))
        self.automaticFrames = automaticFrames
    }
    func update(text: String, value: Int64, animate: Bool = true) {
        let animate = animate && mounted
        guard text != motion.target.text || !animate && motion.isRunning else { return }
        motion.update(text: text, value: value, animate: animate)
        updateClock()
    }
    func measure(height: CGFloat, scale: CGFloat) {
        guard height.isFinite, height > 0, scale.isFinite, scale > 0 else { return }
        let pixels = Int(floor(height * scale + 0.5))
        guard motion.heightPixels != pixels || self.scale != scale else { return }
        stop(); self.scale = scale
        motion = .init(text: motion.target.text, value: motion.target.value, heightPixels: pixels)
    }
    func mount(text: String, value: Int64, height: CGFloat, scale: CGFloat) {
        mounted = true; measure(height: height, scale: scale)
        update(text: text, value: value, animate: false)
    }
    func advance(_ nanos: Int64) {
        guard motion.isRunning else { return }
        motion.advance(nanos)
        if !motion.isRunning { stop() }
    }
    func unmount() {
        mounted = false; stop()
        if motion.isRunning { motion.update(text: motion.target.text, value: motion.target.value, animate: false) }
    }
    private func updateClock() {
        guard motion.isRunning && mounted else { stop(); return }
        guard automaticFrames, link == nil else { return }
        let next = ZTransferDisplayLink.make(owner: self) { owner, link in
            owner.advance(Int64(link.timestamp * 1_000_000_000))
        }
        link = next; next.add(to: .main, forMode: .common)
    }
    private func stop() { link?.invalidate(); link = nil }
}

/// Android AnimatedQueuePillValue: target-only width, independently keyed
/// decimal places, whole-label unit transitions and a single readout for VO.
/// The finite frame clock is owned by this leaf, never by the surrounding card.
struct QueueAnimatedValue: View {
    let text: String
    let value: Int64
    let style: ZTransferTypography
    let weight: Font.Weight
    let color: Color
    var animate = true
    @StateObject private var clock: QueueNumericValueClock
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase

    init(text: String, value: Int64, style: ZTransferTypography = .labelLarge,
         weight: Font.Weight = .bold, color: Color = ZTransferColors.primaryText, animate: Bool = true,
         frameClock: QueueNumericValueClock? = nil) {
        self.text = text; self.value = value; self.style = style; self.weight = weight; self.color = color
        self.animate = animate
        _clock = StateObject(wrappedValue: frameClock ?? QueueNumericValueClock(text: text, value: value, height: style.lineHeight))
    }
    private struct Input: Equatable { let text: String; let value: Int64; let animate: Bool }
    private var input: Input { .init(text: text, value: value, animate: animate && scenePhase == .active) }

    var body: some View {
        glyph(text).hidden()
            .overlay(alignment: .trailing) {
                ZStack(alignment: .trailing) {
                    ForEach(clock.motion.outer.layers) { layer in
                        if let group = clock.motion.groups[layer.key] {
                            groupContent(group)
                                .offset(y: CGFloat(layer.motion.displayedOffsetPixels) / displayScale)
                                .opacity(Double(layer.motion.fade.alpha.value))
                        }
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .transaction { $0.animation = nil }
            .onChange(of: input) { clock.update(text: $0.text, value: $0.value, animate: $0.animate) }
            .onChange(of: displayScale) { clock.measure(height: style.lineHeight, scale: $0) }
            .onChange(of: style.lineHeight) { clock.measure(height: $0, scale: displayScale) }
            .onAppear { clock.mount(text: text, value: value, height: style.lineHeight, scale: displayScale) }
            .onDisappear { clock.unmount() }
    }

    @ViewBuilder private func groupContent(_ group: QueueNumericValueMotion.Group) -> some View {
        if let number = group.snapshot.number {
            HStack(spacing: 0) {
                ForEach(group.places, id: \.self) { place in
                    if let motion = group.digits[place] {
                        glyph(motion.current).hidden()
                            .overlay(alignment: .trailing) {
                                ZStack(alignment: .trailing) {
                                    ForEach(motion.layers) { layer in
                                        glyph(layer.key)
                                            .offset(y: CGFloat(layer.motion.displayedOffsetPixels) / displayScale)
                                            .opacity(Double(layer.motion.fade.alpha.value))
                                    }
                                }
                            }
                            .clipShape(QueueValueVerticalClip())
                    }
                }
                glyph(number.suffix)
            }
        } else { glyph(group.snapshot.text) }
    }

    private func glyph(_ value: String) -> some View {
        Text(value).zTransferTypography(style, weight: weight).foregroundStyle(color)
            .monospacedDigit().lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .frame(height: style.lineHeight)
    }
}

/// Removed leading places have zero target width. Preserve their departing
/// glyph to the left while clipping only vertically, as Android drawWithContent.
private struct QueueValueVerticalClip: Shape {
    func path(in rect: CGRect) -> Path { Path(rect.insetBy(dx: -rect.height, dy: 0)) }
}

struct QueuePillRollingCount: View {
    let count: Int
    var color: Color = ZTransferColors.primaryText
    var animate = true
    var body: some View {
        QueueAnimatedValue(text: String(count), value: Int64(count), color: color, animate: animate)
    }
}
