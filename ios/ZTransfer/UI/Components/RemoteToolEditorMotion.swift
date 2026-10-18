import SwiftUI
import UIKit

/// Offset's vector spring has one shared duration (the maximum axis duration).
/// Do not stop one axis early just because that scalar is within its threshold.
struct RemoteToolPositionMotion {
    private(set) var value: CGPoint
    private(set) var target: CGPoint
    private var velocity = CGPoint.zero
    private var initial: CGPoint
    private var initialVelocity = CGPoint.zero
    private var start: Int64?
    private var lastFrame: Int64?
    private var duration: Int64 = 0
    private(set) var isRunning = false
    // RemoteToolBar.kt / 424c8514, including Offset.VisibilityThreshold.
    private let spec = ZTransferAndroidMotion.underdampedSpring(stiffness: 520, dampingRatio: 0.88, threshold: 0.5)

    init(_ point: CGPoint) { value = point; target = point; initial = point }

    mutating func setTarget(_ point: CGPoint, snap: Bool) {
        if snap { self = Self(point); return }
        guard point != target else { return }
        initial = value; initialVelocity = velocity; target = point
        duration = max(spec.durationNanos(from: Float(value.x), to: Float(point.x), velocity: Float(velocity.x)),
                       spec.durationNanos(from: Float(value.y), to: Float(point.y), velocity: Float(velocity.y)))
        start = lastFrame
        isRunning = true
    }

    mutating func advance(_ now: Int64) {
        guard isRunning else { return }
        if start == nil { start = now }
        let elapsed = max(0, now - start!)
        if elapsed >= duration {
            value = target; velocity = .zero; isRunning = false; start = nil; lastFrame = nil
        } else {
            let x = spec.sample(at: elapsed, from: Float(initial.x), to: Float(target.x), velocity: Float(initialVelocity.x))
            let y = spec.sample(at: elapsed, from: Float(initial.y), to: Float(target.y), velocity: Float(initialVelocity.y))
            value = CGPoint(x: CGFloat(x.value), y: CGFloat(y.value))
            velocity = CGPoint(x: CGFloat(x.velocity), y: CGFloat(y.velocity))
            lastFrame = now
        }
    }
}

struct RemoteToolSlotMotion {
    private(set) var position: RemoteToolPositionMotion
    private(set) var lift = ZTransferScalarAnimation(value: 1)
    private(set) var iconOpacity: ZTransferScalarAnimation
    private(set) var wiggles = false
    private var wiggleStart: Int64?
    private let delay: Int64
    private(set) var angle: Float = 0

    init(tool: RemoteTool, position: CGPoint, visible: Bool) {
        self.position = RemoteToolPositionMotion(position)
        iconOpacity = ZTransferScalarAnimation(value: visible ? 1 : 0.38)
        delay = Int64((RemoteTool.allCases.firstIndex(of: tool)! % 3) * 55) * 1_000_000
    }

    mutating func configure(position target: CGPoint, editing: Bool, visible: Bool, dragging: Bool) {
        position.setTarget(target, snap: dragging)
        lift.retarget(dragging ? 1.10 : 1, using: .tween(milliseconds: 120))
        if editing { iconOpacity.retarget(visible ? 1 : 0.38, using: .tween(milliseconds: 180)) }
        else { iconOpacity.reset(to: visible ? 1 : 0.38) }
        let nextWiggles = editing && visible && !dragging
        if nextWiggles != wiggles {
            wiggles = nextWiggles
            wiggleStart = nil
            angle = wiggles ? -1.3 : 0
        }
    }

    var needsFrames: Bool { wiggles || position.isRunning || lift.isRunning || iconOpacity.isRunning }

    mutating func advance(_ now: Int64) {
        position.advance(now)
        lift.advance(frameNanos: now)
        iconOpacity.advance(frameNanos: now)
        if wiggles {
            if wiggleStart == nil { wiggleStart = now }
            let elapsed = max(0, now - wiggleStart! - delay)
            let period: Int64 = 160_000_000
            let iteration = elapsed / period
            let fraction = Float(elapsed % period) / Float(period)
            angle = iteration % 2 == 0 ? -1.3 + 2.6 * fraction : 1.3 - 2.6 * fraction
        }
    }
}

/// animateContentSize(tween(220)) initializes at the first measured size and
/// reports integer pixels, including when an animation is interrupted.
struct RemoteToolHeightMotion {
    private var animation: ZTransferScalarAnimation?
    private var density: CGFloat = 1
    private(set) var editing = false
    var height: CGFloat? { animation.map { CGFloat(floor($0.value + 0.5)) / density } }
    var isRunning: Bool { animation?.isRunning ?? false }

    mutating func setEditing(_ value: Bool) {
        if value != editing { animation = nil }
        editing = value
    }
    mutating func measure(_ height: CGFloat, scale: CGFloat) {
        guard editing else { return }
        density = max(1, scale)
        let pixels = Float(floor(height * density + 0.5))
        if animation == nil { animation = ZTransferScalarAnimation(value: pixels) }
        else {
            let displayed = floor(animation!.value + 0.5)
            animation?.retarget(pixels, using: .tween(milliseconds: 220), fromDisplayedValue: displayed)
        }
    }
    mutating func advance(_ now: Int64) { animation?.advance(frameNanos: now) }
}

/// A clock owns the animation models; only each changed visual leaf publishes.
/// Android reads these values in graphicsLayer, never recomposing the toolbar
/// layout for every wiggle frame. See performance ledger P21.
@MainActor
final class RemoteToolEditorMotion: NSObject {
    private(set) var states: [RemoteTool: RemoteToolSlotMotion] = [:]
    private(set) var fixedPositions: [String: RemoteToolPositionMotion] = [:]
    private(set) var contentHeight = RemoteToolHeightMotion()
    let heightPresentation = RemoteToolHeightPresentation()
    private var presentations: [RemoteTool: RemoteToolSlotPresentation] = [:]
    private var fixedPresentations: [String: RemoteToolSlotPresentation] = [:]
    private var toolKeys: [RemoteTool] = []
    private var fixedKeys: [String] = []
    private var slots: [RemoteTool: CGRect] = [:]
    private var fixedSlots: [String: CGRect] = [:]
    private var displayLink: CADisplayLink?
    private var density: CGFloat = 1
    private var active = false
    var clockRunning: Bool { displayLink != nil }

    func presentation(_ tool: RemoteTool, visible: Bool) -> RemoteToolSlotPresentation {
        if let value = presentations[tool] { return value }
        let value = RemoteToolSlotPresentation(iconOpacity: visible ? 1 : 0.38)
        presentations[tool] = value
        return value
    }
    func fixedPresentation(_ id: String) -> RemoteToolSlotPresentation {
        if let value = fixedPresentations[id] { return value }
        let value = RemoteToolSlotPresentation()
        fixedPresentations[id] = value
        return value
    }
    func configure(slots: [RemoteTool: CGRect], fixedSlots: [String: CGRect] = [:], editing: Bool, visible: Set<RemoteTool>,
                   dragging: RemoteTool?, topLeft: CGPoint, scale: CGFloat) {
        if self.slots.count != slots.count || self.slots.keys.contains(where: { slots[$0] == nil }) {
            for tool in toolKeys where slots[tool] == nil { presentations.removeValue(forKey: tool) }
            toolKeys = Array(slots.keys)
            states = states.filter { slots[$0.key] != nil }
        }
        if self.fixedSlots.count != fixedSlots.count || self.fixedSlots.keys.contains(where: { fixedSlots[$0] == nil }) {
            for id in fixedKeys where fixedSlots[id] == nil { fixedPresentations.removeValue(forKey: id) }
            fixedKeys = Array(fixedSlots.keys)
            fixedPositions = fixedPositions.filter { fixedSlots[$0.key] != nil }
        }
        self.slots = slots; self.fixedSlots = fixedSlots
        density = max(1, scale)
        contentHeight.setEditing(editing)
        for (tool, slot) in slots {
            let point = tool == dragging ? topLeft : slot.origin
            let pixels = CGPoint(x: point.x * density, y: point.y * density)
            if states[tool] == nil { states[tool] = RemoteToolSlotMotion(tool: tool, position: pixels, visible: visible.contains(tool)) }
            states[tool]?.configure(position: pixels, editing: editing, visible: visible.contains(tool), dragging: dragging == tool)
        }
        for (id, slot) in fixedSlots {
            let pixels = CGPoint(x: slot.minX * density, y: slot.minY * density)
            if fixedPositions[id] == nil { fixedPositions[id] = RemoteToolPositionMotion(pixels) }
            fixedPositions[id]?.setTarget(pixels, snap: false)
        }
        publish(); schedule()
    }

    func measureHeight(_ height: CGFloat, editing: Bool, scale: CGFloat) {
        contentHeight.setEditing(editing)
        contentHeight.measure(height, scale: scale)
        heightPresentation.update(contentHeight.height)
        schedule()
    }
    func setActive(_ active: Bool) { self.active = active; schedule() }
    private func schedule() {
        guard active && needsFrames else { invalidate(); return }
        if displayLink == nil {
            let link = CADisplayLink(target: ClockTarget(self), selector: #selector(ClockTarget.frame(_:)))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }
    }

    func position(_ tool: RemoteTool) -> CGPoint? {
        states[tool].map { CGPoint(x: $0.position.value.x / density, y: $0.position.value.y / density) }
    }
    func fixedPosition(_ id: String) -> CGPoint? {
        fixedPositions[id].map { CGPoint(x: $0.value.x / density, y: $0.value.y / density) }
    }
    private var needsFrames: Bool {
        contentHeight.isRunning || states.values.contains(where: \.needsFrames)
            || fixedPositions.values.contains(where: \.isRunning)
    }
    func advance(_ now: Int64) {
        for tool in toolKeys where states[tool]?.needsFrames == true { states[tool]?.advance(now) }
        for id in fixedKeys where fixedPositions[id]?.isRunning == true { fixedPositions[id]?.advance(now) }
        contentHeight.advance(now)
        publish(); schedule()
    }
    private func publish() {
        for (tool, state) in states {
            let base = slots[tool]?.origin ?? .zero
            let value = RemoteToolSlotPresentation.Display(
                offset: CGSize(width: state.position.value.x / density - base.x,
                               height: state.position.value.y / density - base.y),
                lift: CGFloat(state.lift.value), angle: Double(state.angle), iconOpacity: Double(state.iconOpacity.value))
            presentation(tool, visible: state.iconOpacity.target == 1).update(value)
        }
        for (id, state) in fixedPositions {
            let base = fixedSlots[id]?.origin ?? .zero
            fixedPresentation(id).update(.init(offset: CGSize(width: state.value.x / density - base.x,
                height: state.value.y / density - base.y)))
        }
        heightPresentation.update(contentHeight.height)
    }
    @MainActor private final class ClockTarget: NSObject {
        weak var owner: RemoteToolEditorMotion?
        init(_ owner: RemoteToolEditorMotion) { self.owner = owner }
        @objc func frame(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.advance(Int64(link.timestamp * 1_000_000_000))
        }
    }
    private func invalidate() { displayLink?.invalidate(); displayLink = nil }
    func stop() { setActive(false) }
}

@MainActor
final class RemoteToolSlotPresentation: ObservableObject {
    struct Display: Equatable {
        var offset = CGSize.zero
        var lift: CGFloat = 1
        var angle: Double = 0
        var iconOpacity: Double = 1
    }
    @Published private(set) var display: Display
    init(iconOpacity: Double = 1) { display = Display(iconOpacity: iconOpacity) }
    func update(_ next: Display) { if display != next { display = next } }
}

@MainActor
final class RemoteToolHeightPresentation: ObservableObject {
    @Published private(set) var height: CGFloat?
    func update(_ height: CGFloat?) { if self.height != height { self.height = height } }
}

struct RemoteToolSlotTransform: ViewModifier {
    @ObservedObject var presentation: RemoteToolSlotPresentation
    func body(content: Content) -> some View {
        content.environment(\.remoteToolIconOpacity, presentation.display.iconOpacity)
            .scaleEffect(presentation.display.lift)
            .rotationEffect(.degrees(presentation.display.angle))
            .offset(presentation.display.offset)
    }
}
struct RemoteToolAnimatedHeight: ViewModifier {
    @ObservedObject var presentation: RemoteToolHeightPresentation
    let editing: Bool
    func body(content: Content) -> some View {
        content.frame(height: editing ? presentation.height : nil, alignment: .topLeading)
    }
}

private struct RemoteToolIconOpacityKey: EnvironmentKey { static let defaultValue: Double = 1 }
extension EnvironmentValues {
    var remoteToolIconOpacity: Double {
        get { self[RemoteToolIconOpacityKey.self] }
        set { self[RemoteToolIconOpacityKey.self] = newValue }
    }
}
struct RemoteToolAnimatedMark<Content: View>: View {
    @Environment(\.remoteToolIconOpacity) private var opacity
    @ViewBuilder let content: () -> Content
    var body: some View { content().opacity(opacity) }
}
