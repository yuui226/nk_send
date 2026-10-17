import Foundation

// QueuePill and AnimatedQueuePillCount in Android FileListScreen.kt.
// Pure state only; view clocks and rendering remain in PhotoListView.swift.

enum QueuePillVisualMode: Hashable, CaseIterable {
    case icon, done, paused, generating, counting
}

/// Compose EnterExitTransition alpha rules for QueuePill's AnimatedContent.
/// Kept separate from layer ownership: a retained outgoing layer can reverse.
struct QueuePillFadeMotion {
    enum Phase { case preEnter, visible, postExit }
    private(set) var phase: Phase
    private(set) var alpha: ZTransferScalarAnimation
    private let enterMilliseconds: Int64
    private let enterDelayMilliseconds: Int64
    private let exitMilliseconds: Int64
    private var segmentSpec = ZTransferAndroidMotion.criticallyDampedSpring(stiffness: 400)

    init(initiallyVisible: Bool, enterMilliseconds: Int64 = 220,
         enterDelayMilliseconds: Int64 = 35, exitMilliseconds: Int64 = 160) {
        self.enterMilliseconds = enterMilliseconds
        self.enterDelayMilliseconds = enterDelayMilliseconds
        self.exitMilliseconds = exitMilliseconds
        phase = initiallyVisible ? .visible : .preEnter
        alpha = .init(value: initiallyVisible ? 1 : 0, retainsEndVelocity: true)
    }

    mutating func setVisible(_ visible: Bool, atFrameNanos: Int64? = nil, force: Bool = false) {
        let target: Phase = visible ? .visible : .postExit
        guard phase != target || force else { return }
        if phase != target {
            if phase == .preEnter && target == .visible {
                segmentSpec = .tween(milliseconds: enterMilliseconds, delayMilliseconds: enterDelayMilliseconds)
            } else if phase == .visible && target == .postExit {
                segmentSpec = .tween(milliseconds: exitMilliseconds)
            } else {
                segmentSpec = .criticallyDampedSpring(stiffness: 400)
            }
        }
        var spec = segmentSpec
        if alpha.isRunning, case .tween = spec {
            spec = .criticallyDampedSpring(stiffness: 1500)
        }
        phase = target
        alpha.retarget(visible ? 1 : 0, using: spec, force: true, atFrameNanos: atFrameNanos)
    }

    mutating func advance(_ nanos: Int64) { alpha.advance(frameNanos: nanos) }
    var exitFinished: Bool { phase == .postExit && !alpha.isRunning }
}

/// One number layer in AnimatedQueuePillCount. The count container owns
/// direction and lifetime; opacity finishing alone must not discard the slide.
struct QueuePillCountLayerMotion {
    private(set) var fade: QueuePillFadeMotion
    private(set) var offset: ZTransferScalarAnimation
    private let halfHeightPixels: Float
    private var frame: Int64?
    var isRunning: Bool { fade.alpha.isRunning || offset.isRunning }
    var exitFinished: Bool { fade.exitFinished && !offset.isRunning }
    var displayedOffsetPixels: Float { floor(offset.value + 0.5) }

    init(initiallyVisible: Bool, heightPixels: Int, direction: Int) {
        let halfHeight = Float(max(0, heightPixels) / 2)
        halfHeightPixels = halfHeight
        fade = .init(initiallyVisible: initiallyVisible, enterMilliseconds: 160,
                     enterDelayMilliseconds: 0, exitMilliseconds: 120)
        offset = .init(value: initiallyVisible ? 0 : halfHeight * Float(direction),
                       retainsEndVelocity: true)
    }

    mutating func setVisible(_ visible: Bool, direction: Int, atFrameNanos: Int64? = nil) {
        let origin = atFrameNanos ?? frame
        fade.setVisible(visible, atFrameNanos: origin)
        let displayed = displayedOffsetPixels
        offset.retarget(visible ? 0 : -halfHeightPixels * Float(direction),
                        using: .criticallyDampedSpring(stiffness: 400, threshold: 1),
                        fromDisplayedValue: displayed, force: true, atFrameNanos: origin)
    }

    mutating func restart(atFrameNanos: Int64?) {
        let visible = fade.phase == .visible
        fade.setVisible(visible, atFrameNanos: atFrameNanos, force: true)
        let displayed = displayedOffsetPixels
        let target = offset.target
        offset.retarget(target, using: .criticallyDampedSpring(stiffness: 400, threshold: 1),
                        fromDisplayedValue: displayed, force: true, atFrameNanos: atFrameNanos)
    }

    mutating func advance(_ nanos: Int64) {
        fade.advance(nanos)
        offset.advance(frameNanos: nanos)
        frame = isRunning ? nanos : nil
    }
}

/// Number-keyed ownership mirrors AnimatedContent's retained visible list.
/// Already-exiting layers keep the exit direction chosen when they left.
struct QueuePillCountMotion {
    struct Layer: Identifiable {
        let count: Int
        var motion: QueuePillCountLayerMotion
        var id: Int { count }
    }
    private(set) var current: Int
    private(set) var layers: [Layer]
    private let heightPixels: Int
    private var frame: Int64?
    var isRunning: Bool { layers.contains { $0.motion.isRunning } }

    init(count: Int, heightPixels: Int) {
        current = count
        self.heightPixels = heightPixels
        layers = [.init(count: count, motion: .init(initiallyVisible: true,
                                                    heightPixels: heightPixels, direction: 1))]
    }

    mutating func update(_ next: Int) {
        guard next != current else { return }
        let previous = current
        let direction = next < previous ? 1 : -1
        current = next
        if !layers.contains(where: { $0.count == next }) {
            layers.append(.init(count: next, motion: .init(initiallyVisible: false,
                                                           heightPixels: heightPixels, direction: direction)))
        }
        for index in layers.indices {
            let count = layers[index].count
            if count == next || count == previous {
                layers[index].motion.setVisible(count == next, direction: direction, atFrameNanos: frame)
            } else {
                layers[index].motion.restart(atFrameNanos: frame)
            }
        }
    }

    mutating func advance(_ nanos: Int64) {
        for index in layers.indices { layers[index].motion.advance(nanos) }
        layers.removeAll { $0.count != current && $0.motion.exitFinished }
        frame = isRunning ? nanos : nil
    }
}

struct QueuePillPresentation: Equatable {
    let mode: QueuePillVisualMode
    let count: Int
    let speed: String?
}

struct QueuePillContentMotion {
    struct Layer: Identifiable {
        var presentation: QueuePillPresentation
        var fade: QueuePillFadeMotion
        var id: QueuePillVisualMode { presentation.mode }
    }
    private(set) var layers: [Layer]
    private(set) var current: QueuePillVisualMode
    private var frame: Int64?
    private var targetPresentation: QueuePillPresentation
    var isRunning: Bool { layers.contains { $0.fade.alpha.isRunning } }

    init(_ initial: QueuePillPresentation) {
        current = initial.mode
        targetPresentation = initial
        layers = [.init(presentation: initial, fade: .init(initiallyVisible: true))]
    }

    mutating func update(_ next: QueuePillPresentation) {
        guard next != targetPresentation else { return }
        targetPresentation = next
        if let index = layers.firstIndex(where: { $0.id == next.mode }) {
            layers[index].presentation = next
        } else {
            layers.append(.init(presentation: next, fade: .init(initiallyVisible: false)))
        }
        // contentKey preserves layer identity, while a changed Triple still
        // resets child animation segments. Never reset opacity to zero here.
        current = next.mode
        for index in layers.indices {
            let visible = layers[index].id == current
            layers[index].fade.setVisible(visible, atFrameNanos: frame, force: true)
        }
    }

    mutating func advance(_ nanos: Int64) {
        for index in layers.indices { layers[index].fade.advance(nanos) }
        layers.removeAll { $0.id != current && $0.fade.exitFinished }
        frame = isRunning ? nanos : nil
    }
}

/// FileListScreen.queuePillWidthKey: only equal-width text categories share
/// the counting-mode maximum. Unit/digit/visibility changes start a new group.
struct QueuePillWidthKey: Hashable {
    let mode: QueuePillVisualMode
    let speedUnit: String?
    let speedIntegerDigits: Int
    let countDigits: Int

    init(mode: QueuePillVisualMode, speedText: String?, count: Int) {
        self.mode = mode
        guard mode == .counting || mode == .paused else {
            speedUnit = nil; speedIntegerDigits = 0; countDigits = 0
            return
        }
        if let speedText {
            let parts = speedText.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            speedUnit = parts.count == 2 ? String(parts[1]) : ""
            speedIntegerDigits = parts[0].split(separator: ".", maxSplits: 1,
                                               omittingEmptySubsequences: false)[0].utf16.count
        } else {
            speedUnit = nil; speedIntegerDigits = 0
        }
        countDigits = String(max(0, count)).count
    }
}

struct QueuePillWidthMeasurement {
    private(set) var key: QueuePillWidthKey?
    private(set) var width: CGFloat = 0
    private var maximum: CGFloat = 0

    mutating func measure(_ width: CGFloat, key: QueuePillWidthKey) {
        guard width.isFinite, width > 0 else { return }
        if self.key != key { maximum = width }
        else if key.mode == .counting { maximum = max(maximum, width) }
        self.key = key
        self.width = key.mode == .counting ? max(width, maximum) : width
    }
}

/// QueuePill widthAnim is a Float Animatable in physical pixels. Unlike
/// animateContentSize, interruptions retain its fractional value and velocity.
struct QueueTopPillWidthMotion {
    private var animation: ZTransferScalarAnimation?
    private var density: CGFloat = 1
    var width: CGFloat? { animation.map { CGFloat($0.value) / density } }
    var isRunning: Bool { animation?.isRunning ?? false }

    mutating func update(width: CGFloat, scale: CGFloat) {
        guard width.isFinite, width > 0, scale.isFinite, scale > 0 else { return }
        let pixels = Float(floor(width * scale + 0.5))
        if animation == nil || scale != density {
            animation = .init(value: pixels)
        } else {
            animation?.retarget(pixels, using: .bouncy)
        }
        density = scale
    }

    mutating func advance(_ nanos: Int64) { animation?.advance(frameNanos: nanos) }
}

/// FileListScreen.summarizeQueuePillTasks: generation may retain transferring status.
struct QueuePillTaskSummary {
    private(set) var downloadRemaining = 0
    private(set) var generationRemaining = 0
    private(set) var activeDownload: TransferQueueItem?
    private(set) var progressOwner: TransferQueueItem?
    private(set) var hasCancelled = false
    var hasActive: Bool { activeDownload != nil || generationRemaining > 0 }
    var allDone: Bool { downloadRemaining == 0 && generationRemaining == 0 }

    /// Android only holds back download counts. Generation and completion
    /// always reflect real tasks, even when an enqueue flight is still alive.
    func displayRemaining(heldCount: Int) -> Int {
        downloadRemaining > 0 ? max(0, downloadRemaining - max(0, heldCount)) : generationRemaining
    }

    init(items: [TransferQueueItem]) {
        var firstGenerating: TransferQueueItem?
        var firstWaiting: TransferQueueItem?
        for item in items {
            switch item.status {
            case .waiting:
                downloadRemaining += 1
                if firstWaiting == nil { firstWaiting = item }
            case .transferring:
                if !item.isGeneratingFrame {
                    downloadRemaining += 1
                    if activeDownload == nil { activeDownload = item }
                }
            case .cancelled: hasCancelled = true
            case .completed, .failed: break
            }
            if item.isGeneratingFrame {
                generationRemaining += 1
                if firstGenerating == nil { firstGenerating = item }
            }
        }
        progressOwner = activeDownload ?? firstGenerating ?? firstWaiting
    }
}
