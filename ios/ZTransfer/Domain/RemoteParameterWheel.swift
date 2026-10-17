import Foundation

/// RemoteScreen.kt ParamTile (Android 1.94). This is a live camera wheel:
/// every crossed detent requests a delta; release/cancellation aligns to the
/// latest descriptor, never to a locally predicted value. ReleaseCommitWheel
/// has a different commit lifecycle and must not be used for this control.
struct RemoteParameterWheel {
    struct Configuration: Equatable {
        let descriptor: RemotePropertyDescriptor?
        let autoEnabled: Bool?
        let hasAutoControl: Bool
        let valueWritable: Bool
        let writable: Bool
        let anchor: Int
        let downSign: Int
        var values: [UInt64] { descriptor?.values ?? [] }
        init(descriptor: RemotePropertyDescriptor? = nil, autoEnabled: Bool? = nil, hasAutoControl: Bool = false) {
            self.descriptor = descriptor; self.autoEnabled = autoEnabled; self.hasAutoControl = hasAutoControl
            let values = descriptor?.values ?? []
            valueWritable = descriptor?.writable == true && !values.isEmpty
            writable = valueWritable && autoEnabled != true
            // Android remember(param): compute once per descriptor change,
            // never scan the enum for every visible row on every display frame.
            anchor = descriptor.map { RemoteExposureParameters.anchorIndex(for: $0.property, values: values, current: $0.current) } ?? -1
            downSign = writable ? descriptor.map { RemoteExposureParameters.downStepSign(for: $0.property, values: values) } ?? -1 : -1
        }
        var gestureKey: GestureKey { .init(writable: writable, downSign: downSign, hasAutoControl: hasAutoControl) }
    }
    struct GestureKey: Equatable {
        let writable: Bool
        let downSign: Int
        let hasAutoControl: Bool
    }
    struct Row: Equatable {
        let index: Int
        let value: UInt64
        let offset: Float
        let alpha: Float
        let scale: Float
    }
    private(set) var configuration = Configuration()
    private(set) var dragging = false
    private(set) var position = ZTransferScalarAnimation(value: 0)
    private(set) var neighbors = ZTransferScalarAnimation(value: 0)
    private(set) var loadingAlpha: Float = 0.25
    private var pulseStart: Int64?
    private var raw: Float = 0
    private var lastDetent = 0
    var needsFrames: Bool {
        position.isRunning || neighbors.isRunning || configuration.descriptor == nil
    }
    var showsDragHint: Bool { configuration.writable && configuration.values.count > 3 }

    mutating func configure(_ next: Configuration) {
        let old = configuration
        let wasDragging = dragging
        configuration = next
        if next.gestureKey != old.gestureKey { dragging = false }
        if next.descriptor == nil && old.descriptor != nil { pulseStart = nil; loadingAlpha = 0.25 }
        if !dragging && (next.anchor != old.anchor || next.values != old.values || wasDragging) { synchronize() }
        updateNeighbors()
    }

    mutating func beginDrag() {
        guard configuration.writable else { return }
        dragging = true
        lastDetent = max(0, configuration.anchor)
        raw = Float(lastDetent)
        position.reset(to: raw)
        updateNeighbors()
    }

    /// dy is the consumed vertical delta after touch slop, in points (dp).
    mutating func drag(by dy: Float) -> Int? {
        guard dragging, configuration.writable else { return nil }
        let last = configuration.values.count - 1
        guard last >= 0 else { return nil }
        if lastDetent > last { lastDetent = last; raw = min(raw, Float(last)) }
        raw = min(Float(last) + 1.5, max(-1.5, raw + Float(configuration.downSign) * dy / 18))
        let shown: Float
        if raw < 0 { shown = -min(-raw * 0.3, 0.45) }
        else if raw > Float(last) { shown = Float(last) + min((raw - Float(last)) * 0.3, 0.45) }
        else { shown = raw }
        position.reset(to: shown)
        let detent = min(last, max(0, Int(floor(shown + 0.5))))
        guard detent != lastDetent else { return nil }
        defer { lastDetent = detent }
        return detent - lastDetent
    }

    mutating func endDrag() {
        dragging = false
        synchronize()
        updateNeighbors()
    }

    private mutating func synchronize() {
        // LaunchedEffect cancels the old animateTo before checking the new
        // anchor. Even a target equal to the displayed value must stop the old
        // tween, otherwise it would keep rolling toward a stale camera value.
        position.reset(to: position.value)
        let anchor = configuration.anchor
        guard anchor >= 0 else { return }
        let target = Float(anchor)
        if abs(position.value - target) > 2.5 { position.reset(to: target) }
        else if position.value != target { position.retarget(target, using: .tween(milliseconds: 180)) }
    }

    private mutating func updateNeighbors() {
        neighbors.retarget(dragging || position.isRunning ? 1 : 0, using: .tween(milliseconds: 150))
    }

    mutating func advance(_ now: Int64) {
        position.advance(frameNanos: now)
        updateNeighbors()
        neighbors.advance(frameNanos: now)
        if configuration.descriptor == nil {
            if pulseStart == nil { pulseStart = now }
            let elapsed = max(0, now - pulseStart!)
            let period: Int64 = 900_000_000
            let phase = elapsed % period
            let reverse = elapsed / period % 2 == 1
            let progress = Float(reverse ? period - phase : phase) / Float(period)
            loadingAlpha = 0.25 + 0.30 * ZTransferAndroidMotion.fastOutSlowIn(progress)
        }
    }

    var rows: [Row] {
        guard let descriptor = configuration.descriptor else { return [] }
        let center = Int(floor(position.value + 0.5))
        return ((center - 2)...(center + 2)).compactMap { i in
            guard configuration.values.indices.contains(i) else { return nil }
            let rel = (position.value - Float(i)) * Float(configuration.downSign)
            let centered = min(1, max(0, 1 - abs(rel)))
            return Row(index: i, value: i == configuration.anchor ? descriptor.current : configuration.values[i],
                offset: rel * 18,
                alpha: min(1, max(0, 1 - abs(rel) * 0.62)) * (centered + (1 - centered) * neighbors.value),
                scale: 1 - 0.15 * min(abs(rel), 2))
        }
    }
}

struct RemoteParameterTileGeometry {
    let width: CGFloat
    let height: CGFloat
    var compact: Bool { height < 44 }
    var valueFontSize: CGFloat { compact ? 14 : 16 }
    var valueLineHeight: CGFloat { compact ? 16 : 20 }
    var labelTop: CGFloat { compact ? 2 : 6 }
    var autoBadgeWidth: CGFloat { min(44, max(32, width * 0.32)) }
    var autoBadgeHeight: CGFloat { min(22, max(17, autoBadgeWidth * 0.5)) }
    var autoBadgeFontSize: CGFloat { 7 + min(1, max(0, (autoBadgeWidth - 32) / 12)) * 2 }
    func isAutoTouch(_ point: CGPoint) -> Bool { point.x >= width - 44 && point.y <= 30 }
}
