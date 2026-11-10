import SwiftUI
import UIKit

/// Android QueueRemovalMotion.kt: stagger only the initial visible targets.
func queueRemovalDelays(_ visible: [(UUID, CGFloat)], targets: Set<UUID>, stagger: Bool) -> [UUID: Int] {
    var result: [UUID: Int] = [:]
    for (id, _) in visible.sorted(by: { $0.1 < $1.1 }) where targets.contains(id) && result[id] == nil {
        result[id] = stagger ? min(result.count * 20, 80) : 0
    }
    return result
}

func queueRemovalOpacity(_ progress: Float) -> Float {
    1 - ZTransferAndroidMotion.fastOutSlowIn(min(1, max(0, (1 - progress) / 0.64)))
}

func queueRemovalHeight(_ progress: Float) -> Float {
    1 - ZTransferAndroidMotion.fastOutSlowIn(min(1, max(0, (1 - progress - 0.18) / 0.82)))
}

/// Rows and cleanup use the same delivered frame time, including the first
/// frame. Wall time alone cannot delete a card whose animation has not run.
struct QueueRemovalTimeline {
    let delays: [UUID: Int]
    var durationScale: Double = 1
    private(set) var start: Int64?
    private(set) var finishedIDs: Set<UUID> = []
    var isFinished: Bool { finishedIDs.count == delays.count }

    mutating func advance(_ nanos: Int64) -> [UUID: Float] {
        if start == nil { start = nanos }
        let elapsed = Double(max(0, nanos - start!)) / 1_000_000
        var values: [UUID: Float] = [:]
        for (id, delay) in delays where !finishedIDs.contains(id) {
            let progress: Float = durationScale <= 0 ? 0 :
                Float(1 - min(1, max(0, (elapsed / durationScale - Double(delay)) / 280)))
            values[id] = progress
            if progress <= 0 { finishedIDs.insert(id) }
        }
        return values
    }
}

@MainActor
final class QueueRemovalFrames {
    private var timeline: QueueRemovalTimeline
    private let values: [UUID: AndroidAnimatedOpacity]
    private var ignoredIDs: Set<UUID> = []
    private let automaticFrames: Bool
    private var link: CADisplayLink?
    private var waiter: CheckedContinuation<Void, Error>?
    private var cancelled = false
    var onRowsFinished: (Set<UUID>) -> Void = { _ in }
    var isWaitingForFrames: Bool { waiter != nil }

    init(delays: [UUID: Int], values: [UUID: AndroidAnimatedOpacity], automaticFrames: Bool = true) {
        timeline = QueueRemovalTimeline(delays: delays)
        self.values = values
        self.automaticFrames = automaticFrames
    }

    func ignore(_ id: UUID) { ignoredIDs.insert(id) }

    func advance(_ nanos: Int64) {
        guard !cancelled, waiter != nil else { return }
        let previous = timeline.finishedIDs
        for (id, progress) in timeline.advance(nanos) where !ignoredIDs.contains(id) {
            values[id]?.update(progress)
        }
        let finished = timeline.finishedIDs.subtracting(previous).subtracting(ignoredIDs)
        if !finished.isEmpty { onRowsFinished(finished) }
        if timeline.isFinished { finish() }
    }

    func wait() async throws {
        guard !timeline.delays.isEmpty else { return }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancelled { continuation.resume(throwing: CancellationError()); return }
                waiter = continuation
                if automaticFrames {
                    let next = ZTransferDisplayLink.make(owner: self) { owner, link in
                        owner.advance(Int64(link.timestamp * 1_000_000_000))
                    }
                    link = next
                    next.add(to: .main, forMode: .common)
                }
            }
            // Android's final 40 ms is a settle margin after all frame-driven
            // row animations, not a replacement wall-clock animation timer.
            try await Task.sleep(for: .milliseconds(40))
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() { cancelled = true; finish() }
    private func finish() {
        link?.invalidate(); link = nil
        let continuation = waiter; waiter = nil
        if cancelled { continuation?.resume(throwing: CancellationError()) }
        else { continuation?.resume() }
    }
    // wait/cancel stop the link synchronously on MainActor; the shared weak
    // display-link proxy also invalidates itself if its owner is released.
}

/// Geometry is queried only when an operation begins. Scrolling does not
/// publish a viewport dictionary or invalidate the queue's parent view.
struct QueueRemovalAnchor: UIViewRepresentable {
    let id: UUID
    let value: AndroidAnimatedOpacity
    let coordinator: QueueRemovalCoordinator
    func makeUIView(context: Context) -> Marker { Marker() }
    func updateUIView(_ view: Marker, context: Context) {
        view.id = id; view.value = value; view.coordinator = coordinator
        coordinator.register(view)
    }
    static func dismantleUIView(_ view: Marker, coordinator: ()) { view.coordinator?.unregister(view) }

    final class Marker: UIView {
        var id = UUID()
        var value: AndroidAnimatedOpacity?
        weak var coordinator: QueueRemovalCoordinator?
        override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false }
        required init?(coder: NSCoder) { nil }
        override func layoutSubviews() { super.layoutSubviews(); coordinator?.onLayoutChange?() }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { coordinator?.unregister(self) }
            else { coordinator?.register(self) }
        }
        var visibleOffset: CGFloat? {
            guard window != nil, bounds.height > 0 else { return nil }
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    let frame = convert(bounds, to: scroll)
                    guard frame.maxY > scroll.bounds.minY, frame.minY < scroll.bounds.maxY else { return nil }
                    return frame.minY - scroll.bounds.minY
                }
                ancestor = view.superview
            }
            return nil
        }
    }
}
