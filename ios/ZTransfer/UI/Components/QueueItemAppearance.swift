import SwiftUI
import UIKit

/// Compose 1.7.6 LazyLayoutItemAnimator's previous key map. List index zero
/// belongs to the status group; task keys use the same 30 + 100 nearest range.
struct QueueAppearanceKeyMap {
    private var ids: [UUID] = []
    private var indices: [UUID: Int] = [:]
    private var previousKeys: Set<UUID>?
    private var range: Range<Int>?
    private var changed = true

    @discardableResult mutating func prepare(_ ids: [UUID]) -> Bool {
        guard self.ids != ids else { return false }
        if self.ids.isEmpty != ids.isEmpty { previousKeys = nil; range = nil }
        self.ids = ids
        indices = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0 + 1) })
        changed = true
        return true
    }

    func shouldAppear(_ id: UUID) -> Bool {
        indices[id] != nil && previousKeys.map { !$0.contains(id) } == true
    }

    mutating func measured(visibleIDs: [UUID]) {
        let first = visibleIDs.compactMap { indices[$0] }.min() ?? 0
        let start = first / 30 * 30
        let range = max(0, start - 100)..<(start + 130)
        guard changed || self.range != range else { return }
        let lower = min(ids.count, max(0, range.lowerBound - 1))
        let upper = min(ids.count, max(lower, range.upperBound - 1))
        previousKeys = Set(ids[lower..<upper])
        self.range = range
        changed = false
    }
}

/// A layout checkpoint, not a frame observer. Appearance reads the previous
/// map before this pass commits. No parent publication occurs while scrolling.
@MainActor
final class QueueItemAppearanceTracker: ObservableObject {
    private var keys = QueueAppearanceKeyMap()
    private weak var removal: QueueRemovalCoordinator?
    private weak var checkpoint: QueueAppearanceCheckpoint.Marker?
    private var pending: UInt64?
    private var revision: UInt64 = 0

    func prepare(_ ids: [UUID], removal: QueueRemovalCoordinator) {
        if keys.prepare(ids) { revision &+= 1 }
        if self.removal !== removal {
            self.removal?.onLayoutChange = nil
            self.removal = removal
            removal.onLayoutChange = { [weak self] in self?.checkpoint?.setNeedsLayout() }
        }
    }

    func shouldAppear(_ id: UUID) -> Bool { keys.shouldAppear(id) }

    func attach(_ view: QueueAppearanceCheckpoint.Marker) {
        checkpoint = view
        view.setNeedsLayout()
    }

    func measured() {
        guard pending != revision else { return }
        let revision = revision
        pending = revision
        // Let all rows finish their layout/onAppear before replacing the map.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.revision == revision else { return }
            self.pending = nil
            self.keys.measured(visibleIDs: self.removal?.viewportRows().map(\.0) ?? [])
        }
    }

    func leave() {
        revision &+= 1
        pending = nil
        keys = QueueAppearanceKeyMap()
        removal?.onLayoutChange = nil
        removal = nil
        checkpoint = nil
    }
}

struct QueueAppearanceCheckpoint: UIViewRepresentable {
    let tracker: QueueItemAppearanceTracker
    func makeUIView(context: Context) -> Marker { Marker() }
    func updateUIView(_ view: Marker, context: Context) {
        view.tracker = tracker
        tracker.attach(view)
    }

    final class Marker: UIView {
        weak var tracker: QueueItemAppearanceTracker?
        override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false }
        required init?(coder: NSCoder) { nil }
        override func layoutSubviews() { super.layoutSubviews(); tracker?.measured() }
    }
}

@MainActor
final class QueueItemAppearanceClock: ObservableObject {
    @Published private(set) var opacity: CGFloat
    private(set) var isRunning = false
    private var firstFrame: Int64?
    private var link: CADisplayLink?
    private let automaticFrames: Bool

    init(initiallyHidden: Bool = false, automaticFrames: Bool = true) {
        opacity = initiallyHidden ? 0 : 1
        self.automaticFrames = automaticFrames
    }

    func appear(animated: Bool) {
        guard !isRunning else { return }
        guard animated else { finish(); return }
        if opacity != 0 { opacity = 0 }
        isRunning = true
        firstFrame = nil
        guard automaticFrames else { return }
        let link = CADisplayLink(target: Target(self), selector: #selector(Target.frame(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    func advance(_ nanos: Int64) {
        guard isRunning else { return }
        if firstFrame == nil { firstFrame = nanos }
        let elapsed = max(0, nanos - firstFrame!)
        if elapsed >= 180_000_000 { finish(); return }
        let value = CGFloat(ZTransferAndroidMotion.fastOutSlowIn(Float(elapsed) / 180_000_000))
        if opacity != value { opacity = value }
    }

    func finish() {
        link?.invalidate(); link = nil
        isRunning = false; firstFrame = nil
        if opacity != 1 { opacity = 1 }
    }

    @MainActor private final class Target: NSObject {
        weak var owner: QueueItemAppearanceClock?
        init(_ owner: QueueItemAppearanceClock) { self.owner = owner }
        @objc func frame(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.advance(Int64(link.timestamp * 1_000_000_000))
        }
    }
}

struct QueueItemAppearance: ViewModifier {
    let id: UUID
    let tracker: QueueItemAppearanceTracker
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var clock: QueueItemAppearanceClock

    init(id: UUID, tracker: QueueItemAppearanceTracker, clock: QueueItemAppearanceClock? = nil) {
        self.id = id; self.tracker = tracker
        _clock = StateObject(wrappedValue: clock ?? QueueItemAppearanceClock(initiallyHidden: tracker.shouldAppear(id)))
    }

    func body(content: Content) -> some View {
        content.opacity(clock.opacity)
            .onAppear { clock.appear(animated: scenePhase == .active && tracker.shouldAppear(id)) }
            .onDisappear { clock.finish() }
            .onChange(of: scenePhase) { if $0 != .active { clock.finish() } }
    }
}
