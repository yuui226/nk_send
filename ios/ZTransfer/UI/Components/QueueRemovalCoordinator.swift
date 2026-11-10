import SwiftUI

/// TransferScreen.scheduleRemoval: the page owns cleanup, including finally
/// when a row scrolls away or the page closes. IDs are captured before waiting.
@MainActor
final class QueueRemovalCoordinator: ObservableObject {
    @Published private(set) var removingIDs: Set<UUID> = []
    @Published private(set) var isClearing = false
    private struct Anchor { weak var view: QueueRemovalAnchor.Marker? }
    private struct Operation {
        var task: Task<Void, Never>?
        var frames: QueueRemovalFrames?
        var targets: Set<UUID> = []
        var visible: Set<UUID> = []
        let singleID: UUID?
    }
    private var anchors: [UUID: Anchor] = [:]
    private var values: [UUID: AndroidAnimatedOpacity] = [:]
    private var operations: [UUID: Operation] = [:]
    private let automaticFrames: Bool
    private let visibleRows: (() -> [(UUID, CGFloat)])?
    var onLayoutChange: (() -> Void)?
    var isWaitingForFrames: Bool { operations.values.contains { $0.frames?.isWaitingForFrames == true } }

    init(automaticFrames: Bool = true, visibleRows: (() -> [(UUID, CGFloat)])? = nil) {
        self.automaticFrames = automaticFrames
        self.visibleRows = visibleRows
    }

    func value(for id: UUID) -> AndroidAnimatedOpacity {
        if let value = values[id] { return value }
        let value = AndroidAnimatedOpacity(); value.update(1); values[id] = value
        return value
    }

    func register(_ view: QueueRemovalAnchor.Marker) {
        anchors[view.id] = Anchor(view: view)
        if let value = view.value { values[view.id] = value }
        onLayoutChange?()
    }

    func unregister(_ view: QueueRemovalAnchor.Marker) {
        guard anchors[view.id]?.view === view else { return }
        anchors[view.id] = nil
        if !removingIDs.contains(view.id) { values[view.id] = nil }
        onLayoutChange?()
    }

    func viewportRows() -> [(UUID, CGFloat)] {
        visibleRows?() ?? anchors.compactMap { id, anchor in anchor.view?.visibleOffset.map { (id, $0) } }
    }

    func withdraw(_ id: UUID, model: TransferQueueViewModel) {
        guard !removingIDs.contains(id), !operations.values.contains(where: { $0.singleID == id }) else { return }
        start(singleID: id, model: model)
    }

    func clear(model: TransferQueueViewModel) {
        guard !isClearing else { return }
        isClearing = true
        start(singleID: nil, model: model)
    }

    private func start(singleID: UUID?, model: TransferQueueViewModel) {
        let id = UUID()
        operations[id] = Operation(singleID: singleID)
        operations[id]?.task = Task { @MainActor [weak self] in
            let captured: Set<UUID>
            if let singleID { captured = await model.beginRemoval(id: singleID) }
            else { captured = await model.beginClearQueue() }
            guard !Task.isCancelled, let prepared = self?.prepare(captured, operation: id, model: model) else {
                await model.finishClearQueue(targetIDs: captured)
                self?.finish(id)
                return
            }
            await model.finishClearQueue(targetIDs: prepared.targets.subtracting(prepared.visible))
            do { try await prepared.frames.wait() } catch { /* finally below also runs on page exit. */ }
            await model.finishClearQueue(targetIDs: prepared.targets)
            self?.finish(id)
        }
    }

    private func prepare(_ captured: Set<UUID>, operation id: UUID, model: TransferQueueViewModel)
        -> (targets: Set<UUID>, visible: Set<UUID>, frames: QueueRemovalFrames)? {
        guard var operation = operations[id] else { return nil }
        // An already animating single-card removal keeps its own frame clock.
        let targets = captured.subtracting(operations.filter { $0.key != id }.values.reduce(into: Set<UUID>()) {
            $0.formUnion($1.targets)
        })
        let viewport = viewportRows()
        let delays = queueRemovalDelays(viewport, targets: targets, stagger: operation.singleID == nil)
        let visible = Set(delays.keys)
        let frameValues = Dictionary(uniqueKeysWithValues: visible.map { ($0, value(for: $0)) })
        let frames = QueueRemovalFrames(delays: delays, values: frameValues, automaticFrames: automaticFrames)
        frames.onRowsFinished = { [weak self] ids in
            Task { @MainActor [weak self] in
                let retained = await model.removeAndReturnRetained(ids: ids)
                guard self?.operations[id] != nil else { return }
                // Successful rows stay collapsed until the actor snapshot
                // reaches SwiftUI. Rejected (now busy) rows remain protected.
                self?.restore(retained, operation: id)
            }
        }
        operation.targets = targets; operation.visible = visible; operation.frames = frames
        operations[id] = operation
        removingIDs.formUnion(visible)
        return (targets, visible, frames)
    }

    private func restore(_ ids: Set<UUID>, operation: UUID) {
        for id in ids { operations[operation]?.frames?.ignore(id); values[id]?.update(1) }
        removingIDs.subtract(ids)
    }

    private func finish(_ id: UUID) {
        guard let operation = operations.removeValue(forKey: id) else { return }
        // finishClearQueue has returned, but its publication can still be in
        // flight. synchronize removes successful markers without reflashing.
        if operation.singleID == nil { isClearing = false }
    }

    func synchronize(liveIDs: Set<UUID>) {
        let retained = removingIDs.intersection(liveIDs)
        if retained != removingIDs { removingIDs = retained }
        for id in values.keys where !liveIDs.contains(id) { values[id] = nil; anchors[id] = nil }
    }

    /// Also used by deterministic tests: a stalled frame clock never starts
    /// the final cleanup's settle timer.
    func advance(_ nanos: Int64) {
        for operation in operations.values { operation.frames?.advance(nanos) }
    }

    func leave() {
        for operation in operations.values { operation.task?.cancel(); operation.frames?.cancel() }
        operations.removeAll(); removingIDs.removeAll(); isClearing = false
        anchors.removeAll(); values.removeAll()
    }

    deinit { for operation in operations.values { operation.task?.cancel() } }
}
