import SwiftUI
import UIKit

/// Flight endpoints use a stable right edge/center, independent of the pill's
/// animated width and catch transform. Never publish width frames to the grid.
struct QueueTopFlightAnchor: View {
    var body: some View {
        Color.clear.frame(width: 1, height: 36)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: PhotoListQueueTargetPreferenceKey.self,
                                       value: proxy.frame(in: .global))
            })
            .allowsHitTesting(false)
    }
}

/// SharedQueueControls AnimatedVisibility: keep the slot until both channels
/// finish, but revoke interaction as soon as the target becomes hidden.
struct QueueTopPresenceMotion {
    enum Kind { case execution, pill }
    let kind: Kind
    private(set) var visible: Bool
    private(set) var retained: Bool
    private(set) var alpha: ZTransferScalarAnimation
    private(set) var scale: ZTransferScalarAnimation
    private var frame: Int64?
    var isRunning: Bool { alpha.isRunning || scale.isRunning }
    init(visible: Bool, kind: Kind) {
        self.kind = kind; self.visible = visible; retained = visible
        alpha = .init(value: visible ? 1 : 0, retainsEndVelocity: true)
        scale = .init(value: visible ? 1 : (kind == .execution ? 0.72 : 0.6), retainsEndVelocity: true)
    }
    mutating func update(_ next: Bool) {
        guard visible != next else { return }
        let reversing = isRunning
        visible = next; retained = true
        let fade: ZTransferAndroidMotion = kind == .pill ? .criticallyDampedSpring(stiffness: 400)
            : (reversing ? .criticallyDampedSpring(stiffness: 1500) : .tween(milliseconds: next ? 160 : 120))
        let sizing: ZTransferAndroidMotion = kind == .pill ? .criticallyDampedSpring(stiffness: 400)
            : (next ? .bouncy : (reversing ? .criticallyDampedSpring(stiffness: 1500) : .tween(milliseconds: 140)))
        alpha.retarget(next ? 1 : 0, using: fade, atFrameNanos: frame)
        scale.retarget(next ? 1 : (kind == .execution ? 0.72 : 0.6), using: sizing, atFrameNanos: frame)
    }
    mutating func advance(_ nanos: Int64) {
        alpha.advance(frameNanos: nanos); scale.advance(frameNanos: nanos)
        frame = isRunning ? nanos : nil
        if !visible && !isRunning { retained = false }
    }
}

@MainActor
final class QueueTopPresenceClock: ObservableObject {
    @Published private(set) var motion: QueueTopPresenceMotion
    private var link: CADisplayLink?
    var isTicking: Bool { link != nil }
    init(visible: Bool, kind: QueueTopPresenceMotion.Kind) { motion = .init(visible: visible, kind: kind) }
    func update(_ visible: Bool) {
        if visible != motion.visible { motion.update(visible) }
        resume()
    }
    func resume() {
        guard motion.isRunning, link == nil else { return }
        let next = ZTransferDisplayLink.make(owner: self) { $0.advance(Int64($1.timestamp * 1_000_000_000)) }
        link = next; next.add(to: .main, forMode: .common)
    }
    func advance(_ nanos: Int64) { motion.advance(nanos); if !motion.isRunning { stop() } }
    func stop() { link?.invalidate(); link = nil }
}

struct QueueTopPresence<Content: View>: View {
    let visible: Bool
    let trailingSpacing: CGFloat
    @StateObject private var clock: QueueTopPresenceClock
    @Environment(\.scenePhase) private var scenePhase
    let content: Content
    init(visible: Bool, kind: QueueTopPresenceMotion.Kind, trailingSpacing: CGFloat = 0,
         @ViewBuilder content: () -> Content) {
        self.visible = visible; self.trailingSpacing = trailingSpacing; self.content = content()
        _clock = StateObject(wrappedValue: QueueTopPresenceClock(visible: visible, kind: kind))
    }
    var body: some View {
        Group {
            if clock.motion.retained {
                content
                    .scaleEffect(CGFloat(clock.motion.scale.value))
                    .opacity(Double(clock.motion.alpha.value))
                    .allowsHitTesting(visible)
                    .accessibilityHidden(!visible)
                    .padding(.trailing, trailingSpacing)
            }
        }
        .transaction { $0.animation = nil }
        .onAppear { clock.update(visible) }
        .onChange(of: visible) { clock.update($0) }
        .onChange(of: scenePhase) { if $0 == .active { clock.resume() } else { clock.stop() } }
        .onDisappear { clock.stop() }
    }
}

struct QueueExecutionIconMotion {
    struct Layer: Identifiable {
        let id: TransferQueueSnapshot.ExecutionControl
        var fade: QueuePillFadeMotion
        var scale: ZTransferScalarAnimation
    }
    private(set) var current: TransferQueueSnapshot.ExecutionControl
    private(set) var layers: [Layer]
    private var frame: Int64?
    var isRunning: Bool { layers.contains { $0.fade.alpha.isRunning || $0.scale.isRunning } }
    init(_ control: TransferQueueSnapshot.ExecutionControl) {
        current = control
        layers = [.init(id: control, fade: .init(initiallyVisible: true,
            enterMilliseconds: 150, enterDelayMilliseconds: 35, exitMilliseconds: 100),
            scale: .init(value: 1, retainsEndVelocity: true))]
    }
    mutating func update(_ next: TransferQueueSnapshot.ExecutionControl) {
        guard next != current else { return }
        current = next
        if !layers.contains(where: { $0.id == next }) {
            layers.append(.init(id: next, fade: .init(initiallyVisible: false,
                enterMilliseconds: 150, enterDelayMilliseconds: 35, exitMilliseconds: 100),
                scale: .init(value: 0.72, retainsEndVelocity: true)))
        }
        for index in layers.indices {
            let entering = layers[index].id == next
            let spec: ZTransferAndroidMotion = layers[index].scale.isRunning
                ? .criticallyDampedSpring(stiffness: 1500)
                : .tween(milliseconds: entering ? 175 : 120, delayMilliseconds: entering ? 25 : 0)
            layers[index].fade.setVisible(entering, atFrameNanos: frame)
            layers[index].scale.retarget(entering ? 1 : 0.72, using: spec, atFrameNanos: frame)
        }
    }
    mutating func advance(_ nanos: Int64) {
        for index in layers.indices {
            layers[index].fade.advance(nanos); layers[index].scale.advance(frameNanos: nanos)
        }
        layers.removeAll { $0.id != current && $0.fade.exitFinished && !$0.scale.isRunning }
        frame = isRunning ? nanos : nil
    }
}

@MainActor
final class QueueExecutionClock: ObservableObject {
    @Published private(set) var icons: QueueExecutionIconMotion
    @Published private(set) var active: Float
    @Published private(set) var accent: UInt32
    private var activeMotion: ZTransferScalarAnimation
    private var color: ZTransferColorAnimation
    private var link: CADisplayLink?
    var isTicking: Bool { link != nil }
    init(control: TransferQueueSnapshot.ExecutionControl, requested: Bool, accent: UInt32) {
        let initialActive: Float = control == .pause && requested ? 1 : 0
        icons = .init(control); active = initialActive
        activeMotion = .init(value: initialActive); self.accent = accent
        color = .init(accent, durationMilliseconds: 180)
    }
    func update(control: TransferQueueSnapshot.ExecutionControl?, requested: Bool, accent: UInt32) {
        // nil freezes the outgoing icon; never replace it by START on dismissal.
        guard let control else { return }
        if control != icons.current { icons.update(control) }
        activeMotion.retarget(control == .pause && requested ? 1 : 0, using: .tween(milliseconds: 180))
        color.retarget(accent); resume()
    }
    func resume() {
        guard icons.isRunning || activeMotion.isRunning || color.isRunning, link == nil else { return }
        let next = ZTransferDisplayLink.make(owner: self) { $0.advance(Int64($1.timestamp * 1_000_000_000)) }
        link = next; next.add(to: .main, forMode: .common)
    }
    func advance(_ nanos: Int64) {
        if icons.isRunning { icons.advance(nanos) }
        activeMotion.advance(frameNanos: nanos); color.advance(nanos)
        if active != activeMotion.value { active = activeMotion.value }
        if accent != color.value { accent = color.value }
        if !icons.isRunning && !activeMotion.isRunning && !color.isRunning { stop() }
    }
    func stop() { link?.invalidate(); link = nil }
}

struct QueueTopExecutionButton: View {
    let control: TransferQueueSnapshot.ExecutionControl?
    let pauseRequested: Bool
    let startEnabled: Bool
    let action: (TransferQueueSnapshot.ExecutionControl) -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        QueueExecutionButtonContent(control: control, pauseRequested: pauseRequested,
            startEnabled: startEnabled,
            accent: QueueCardAccentAnimator.packed(control == .pause
                ? ZTransferColors.accentYellow : ZTransferColors.accentBlue, scheme: scheme), action: action)
    }
}

/// Resolve environment colors before constructing the retained animation owner,
/// so mounting in dark mode never flashes the light palette for 180ms.
private struct QueueExecutionButtonContent: View {
    let control: TransferQueueSnapshot.ExecutionControl?
    let pauseRequested: Bool
    let startEnabled: Bool
    let accent: UInt32
    let action: (TransferQueueSnapshot.ExecutionControl) -> Void
    @StateObject private var clock: QueueExecutionClock
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("skin_preset") private var skinPreset = ZTransferButtonSkin.defaultPreset.rawValue
    init(control: TransferQueueSnapshot.ExecutionControl?, pauseRequested: Bool, startEnabled: Bool, accent: UInt32,
         action: @escaping (TransferQueueSnapshot.ExecutionControl) -> Void) {
        self.control = control; self.pauseRequested = pauseRequested; self.startEnabled = startEnabled
        self.accent = accent; self.action = action
        let initial = control ?? .start
        _clock = StateObject(wrappedValue: QueueExecutionClock(control: initial, requested: pauseRequested,
            accent: accent))
    }
    private var enabled: Bool { control != nil && (control == .pause || startEnabled) }
    private var visuallyEnabled: Bool { (control ?? clock.icons.current) == .pause || startEnabled }
    private var nativeGlass: Bool { ZTransferButtonSkin(storedValue: skinPreset) == .liquidGlass }
    private struct Input: Equatable {
        let control: TransferQueueSnapshot.ExecutionControl?
        let requested: Bool
        let accent: UInt32
    }
    private var input: Input { .init(control: control, requested: pauseRequested, accent: accent) }
    private var label: some View {
        ZStack {
            Circle().fill(QueueCardAccentAnimator.color(clock.accent).opacity(0.16 * Double(clock.active)))
            ForEach(clock.icons.layers) { layer in
                QueueTopIcon(kind: layer.id == .start ? .play : .pause)
                    .fill(QueueCardAccentAnimator.color(clock.accent))
                    .frame(width: layer.id == .start ? 21 : 18, height: layer.id == .start ? 21 : 18)
                    .scaleEffect(CGFloat(layer.scale.value)).opacity(Double(layer.fade.alpha.value))
            }
        }
        .frame(width: 32, height: 32).contentShape(Circle())
    }
    var body: some View {
        Group {
            if nativeGlass {
                Button { if let control, enabled { action(control) } } label: { label }
                    .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 16, disabledAlpha: 1))
            } else {
                Button { if let control, enabled { action(control) } } label: { label }
                    .buttonStyle(QueueExecutionPhysicalStyle())
            }
        }
        .disabled(!visuallyEnabled)
        .allowsHitTesting(control != nil)
        .opacity(!visuallyEnabled ? 0.45 : 1)
        .accessibilityLabel(AppLocalized.resource(clock.icons.current == .start ? "cd_start_transfers"
            : (pauseRequested ? "cd_pause_after_current_scheduled" : "cd_pause_after_current")))
        .transaction { $0.animation = nil }
        .onAppear { update(input) }
        // Consume the new payload rather than the View captured by an older
        // callback. Separate control/color callbacks could restore START after
        // receiving PAUSE during the same SwiftUI update.
        .onChange(of: input) { update($0) }
        .onChange(of: scenePhase) { if $0 == .active { clock.resume() } else { clock.stop() } }
        .onDisappear { clock.stop() }
        .background {
#if DEBUG
            Color.clear.preference(key: QueueExecutionObservationKey.self,
                value: .init(control: control, displayed: clock.icons.current, accent: clock.accent,
                             layers: clock.icons.layers.count, ticking: clock.isTicking))
#endif
        }
    }
    private func update(_ input: Input) {
        clock.update(control: input.control, requested: input.requested, accent: input.accent)
    }
}

#if DEBUG
struct QueueExecutionObservation: Equatable {
    let control: TransferQueueSnapshot.ExecutionControl?
    let displayed: TransferQueueSnapshot.ExecutionControl
    let accent: UInt32
    let layers: Int
    let ticking: Bool
}
struct QueueExecutionObservationKey: PreferenceKey {
    static let defaultValue: QueueExecutionObservation? = nil
    static func reduce(value: inout QueueExecutionObservation?, nextValue: () -> QueueExecutionObservation?) {
        if let next = nextValue() { value = next }
    }
}
#endif

private struct QueueExecutionPhysicalStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(ZTransferGlassSurface(cornerRadius: 16, kind: .button))
            .clipShape(Circle())
            .modifier(QueuePillPressEffect(pressed: configuration.isPressed, nativeGlass: false, pressedScale: 0.92))
    }
}

/// SharedQueueControls catch: the second phase is driven by the same displayed
/// frame as the first phase, rather than an unrelated sleeping Task.
struct QueueTopCatchMotion {
    private(set) var scale = ZTransferScalarAnimation(value: 1)
    private var rising = false
    var isRunning: Bool { scale.isRunning }
    mutating func trigger() { rising = true; scale.retarget(1.18, using: .tween(milliseconds: 110), force: true) }
    mutating func advance(_ nanos: Int64) {
        scale.advance(frameNanos: nanos)
        if rising && !scale.isRunning {
            rising = false; scale.retarget(1, using: .bouncy, atFrameNanos: nanos)
        }
    }
}

@MainActor
final class QueueTopCatchClock: ObservableObject {
    @Published private(set) var motion = QueueTopCatchMotion()
    private var lastTrigger: Int?
    private var link: CADisplayLink?
    var isTicking: Bool { link != nil }
    func mount(_ trigger: Int) { stop(); lastTrigger = trigger; motion = .init() }
    func update(_ trigger: Int) {
        guard lastTrigger != trigger else { return }
        guard lastTrigger != nil else { mount(trigger); return }
        lastTrigger = trigger; motion.trigger(); resume()
    }
    func resume() {
        guard motion.isRunning, link == nil else { return }
        let next = ZTransferDisplayLink.make(owner: self) { $0.advance(Int64($1.timestamp * 1_000_000_000)) }
        link = next; next.add(to: .main, forMode: .common)
    }
    func advance(_ nanos: Int64) { motion.advance(nanos); if !motion.isRunning { stop() } }
    func stop() { link?.invalidate(); link = nil }
}

struct QueueControlsCatchEffect: ViewModifier {
    let trigger: Int
    @StateObject private var clock = QueueTopCatchClock()
    @Environment(\.scenePhase) private var scenePhase
    func body(content: Content) -> some View {
        content.scaleEffect(CGFloat(clock.motion.scale.value), anchor: .trailing)
            .transaction { $0.animation = nil }
            .onAppear { clock.mount(trigger) }
            .onChange(of: trigger) { clock.update($0) }
            .onChange(of: scenePhase) { if $0 == .active { clock.resume() } else { clock.stop() } }
            .onDisappear { clock.stop() }
    }
}
