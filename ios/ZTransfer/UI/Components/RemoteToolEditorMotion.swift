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
    private let spec = ZTransferAndroidMotion.underdampedSpring(stiffness: 500, dampingRatio: 0.86)

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
        position.setTarget(target, snap: dragging || !editing)
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

/// One display clock per toolbar, shared by every slot and suspended when idle.
@MainActor
final class RemoteToolEditorMotion: NSObject, ObservableObject {
    @Published private(set) var states: [RemoteTool: RemoteToolSlotMotion] = [:]
    @Published private(set) var fixedPositions: [String: RemoteToolPositionMotion] = [:]
    @Published private(set) var contentHeight = RemoteToolHeightMotion()
    private var displayLink: CADisplayLink?
    private var density: CGFloat = 1

    func configure(slots: [RemoteTool: CGRect], fixedSlots: [String: CGRect] = [:], editing: Bool, visible: Set<RemoteTool>,
                   dragging: RemoteTool?, topLeft: CGPoint, scale: CGFloat) {
        density = max(1, scale)
        contentHeight.setEditing(editing)
        var next = states.filter { slots[$0.key] != nil }
        for (tool, slot) in slots {
            let point = tool == dragging ? topLeft : slot.origin
            let pixels = CGPoint(x: point.x * density, y: point.y * density)
            if next[tool] == nil { next[tool] = RemoteToolSlotMotion(tool: tool, position: pixels, visible: visible.contains(tool)) }
            next[tool]?.configure(position: pixels, editing: editing, visible: visible.contains(tool), dragging: dragging == tool)
        }
        states = next
        var fixed = fixedPositions.filter { fixedSlots[$0.key] != nil }
        for (id, slot) in fixedSlots {
            let pixels = CGPoint(x: slot.minX * density, y: slot.minY * density)
            if fixed[id] == nil { fixed[id] = RemoteToolPositionMotion(pixels) }
            fixed[id]?.setTarget(pixels, snap: !editing)
        }
        fixedPositions = fixed
        schedule()
    }

    func measureHeight(_ height: CGFloat, editing: Bool, scale: CGFloat) {
        contentHeight.setEditing(editing)
        contentHeight.measure(height, scale: scale)
        schedule()
    }

    private func schedule() {
        if needsFrames, displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
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

    @objc private func frame(_ link: CADisplayLink) {
        var next = states
        let now = Int64(link.timestamp * 1_000_000_000)
        for tool in next.keys { next[tool]?.advance(now) }
        states = next
        var fixed = fixedPositions
        for id in fixed.keys { fixed[id]?.advance(now) }
        fixedPositions = fixed
        contentHeight.advance(now)
        if !needsFrames { stop() }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
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
