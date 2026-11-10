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

struct QueuePillPresentation: Equatable {
    let mode: QueuePillVisualMode
    let count: Int
    /// Keep the real sample so numeric transitions know the direction without
    /// parsing localized/formatted text. Outgoing modes retain this snapshot.
    let speed: Int64?
    var showDone = true
}

func queuePillVisibilityFeather(width: CGFloat, naturalWidth: CGFloat, transitioning: Bool) -> Double {
    guard transitioning, naturalWidth > 0 else { return 0 }
    let fraction = min(1, max(0, Double((1 - width / naturalWidth) / 0.18)))
    return fraction * fraction * (3 - 2 * fraction)
}

func transferSpeedText(_ bytesPerSecond: Int64) -> String {
    let speed = max(0, bytesPerSecond)
    switch speed {
    case ..<1024: return "\(speed) B/s"
    case ..<(1024 * 1024): return String(format: "%.1f KB/s", Double(speed) / 1024)
    default: return String(format: "%.1f MB/s", Double(speed) / (1024 * 1024))
    }
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
    private var surfaceFade: QueuePillFadeMotion
    private var lastContentMode: QueuePillVisualMode
    var isRunning: Bool { surfaceFade.alpha.isRunning || layers.contains { $0.fade.alpha.isRunning } }

    init(_ initial: QueuePillPresentation) {
        current = initial.mode
        targetPresentation = initial
        surfaceFade = .init(initiallyVisible: initial.mode != .icon)
        lastContentMode = initial.mode
        layers = [.init(presentation: initial, fade: .init(initiallyVisible: true))]
    }

    struct Surface {
        let iconAlpha: Double
        let fillAlpha: Double
        let hasContent: Bool
        let finishingExit: Bool
    }
    var surface: Surface {
        let fillAlpha = min(1, max(0, Double(surfaceFade.alpha.value)))
        return Surface(iconAlpha: 1 - fillAlpha, fillAlpha: fillAlpha,
            hasContent: fillAlpha > 0 || layers.contains { $0.id != .icon },
            finishingExit: current == .icon && lastContentMode == .done)
    }

    mutating func update(_ next: QueuePillPresentation) {
        guard next != targetPresentation else { return }
        targetPresentation = next
        surfaceFade.setVisible(next.mode != .icon, atFrameNanos: frame)
        if next.mode != .icon { lastContentMode = next.mode }
        if let index = layers.firstIndex(where: { $0.id == next.mode }) {
            layers[index].presentation = next
        } else {
            layers.append(.init(presentation: next, fade: .init(initiallyVisible: false)))
        }
        // A settled mode only changes its readout. Do not start a new display
        // link/alpha segment for each 200ms speed sample. Interrupted mode fades
        // still follow the original retained-layer rules below.
        if next.mode == current, !isRunning { return }
        // contentKey preserves layer identity, while a changed Triple still
        // resets child animation segments. Never reset opacity to zero here.
        current = next.mode
        for index in layers.indices {
            let visible = layers[index].id == current
            layers[index].fade.setVisible(visible, atFrameNanos: frame, force: true)
        }
    }

    mutating func advance(_ nanos: Int64) {
        surfaceFade.advance(nanos)
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
        guard width.isFinite, width >= 0 else { return }
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
    var width: CGFloat? { animation.map { max(0, CGFloat($0.value) / density) } }
    var isRunning: Bool { animation?.isRunning ?? false }

    mutating func update(width: CGFloat, scale: CGFloat) {
        guard width.isFinite, width >= 0, scale.isFinite, scale > 0 else { return }
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
    var progressOwner: TransferQueueItem? { activeDownload }
    private(set) var hasCancelled = false
    var hasActive: Bool { activeDownload != nil || generationRemaining > 0 }
    var allDone: Bool { downloadRemaining == 0 && generationRemaining == 0 }

    /// Android only holds back download counts. Generation and completion
    /// always reflect real tasks, even when an enqueue flight is still alive.
    func displayRemaining(heldCount: Int) -> Int {
        downloadRemaining > 0 ? max(0, downloadRemaining - max(0, heldCount)) : generationRemaining
    }

    func allDownloadsAreInFlight(heldCount: Int) -> Bool {
        downloadRemaining > 0 && heldCount > 0 && displayRemaining(heldCount: heldCount) == 0
    }

    init(items: [TransferQueueItem]) {
        for item in items {
            switch item.status {
            case .waiting:
                if !item.isGeneratingFrame {
                    downloadRemaining += 1
                }
            case .transferring:
                if !item.isGeneratingFrame {
                    downloadRemaining += 1
                    if activeDownload == nil { activeDownload = item }
                }
            case .cancelled: hasCancelled = true
            case .completed, .failed: break
            }
            if item.isQueuedForFrameGeneration {
                generationRemaining += 1
            }
        }
    }
}
