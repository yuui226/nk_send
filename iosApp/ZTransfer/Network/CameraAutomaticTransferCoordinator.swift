import Foundation
import ZTransferShared

/// The only admission surface is the existing original-file queue; no second queue or directory owner.
protocol CameraAutomaticTransferAdmitting: AnyObject {
    func enqueueNewMedia(_ infos: [PtpObjectInfo], files: [CameraFileInfo], enabled: Bool,
                         byDate: Bool, dayKey: Int32, deferred: Bool) async -> Int
}

extension CameraOriginalQueue: CameraAutomaticTransferAdmitting {}

/// Connection-owned delivery of actual catalog additions. MainActor also owns the settings UI,
/// so enabling/disabling, option snapshots and lifetime invalidation have one ordering boundary.
@MainActor
final class CameraAutomaticTransferCoordinator {
    private struct Candidate {
        let info: PtpObjectInfo
        let file: CameraFileInfo
        let byDate: Bool
        let dayKey: Int32
        let deferred: Bool
    }

    private let connectionID: UUID
    private let queue: CameraAutomaticTransferAdmitting
    private let preferences: TransferPreferencesStore
    private let dayKey: @MainActor () -> Int32
    private var closed = false
    private var lastSeenPublication: UInt64?
    private var seenHandles = Set<Int32>()
    private var pending: [Candidate] = []
    private var pendingIndex = 0
    private var worker: Task<Void, Never>?
    private var workerToken: UUID?

    init(connectionID: UUID, queue: CameraAutomaticTransferAdmitting,
         preferences: TransferPreferencesStore, dayKey: @escaping @MainActor () -> Int32 = {
             OriginalFilesPageBridge.localDayKey(at: Date(), timeZone: .current)
         }) {
        self.connectionID = connectionID; self.queue = queue
        self.preferences = preferences; self.dayKey = dayKey
    }

    deinit { worker?.cancel() }

    var enabled: Bool? { preferences.readAutomatic() }

    /// Must only receive the catalog's onAddition channel, never a whole scan or a metadata refresh.
    /// Observing a disabled event consumes it: subsequently enabling the option never backfills it.
    func receive(_ addition: CameraCatalogAddition, transfer: NativeTransferPreferences? = nil) {
        guard !closed, addition.snapshot.connectionID == connectionID,
              lastSeenPublication.map({ addition.snapshot.publicationRevision >= $0 }) ?? true else { return }
        if lastSeenPublication != addition.snapshot.publicationRevision { seenHandles.removeAll() }
        lastSeenPublication = addition.snapshot.publicationRevision
        // One stable catch-up snapshot can publish several new handles. Deduplicate deliveries,
        // not the entire snapshot; logical backup identity remains the shared queue's decision.
        guard seenHandles.insert(addition.info.handle).inserted else { return }
        guard addition.snapshot.metadataComplete, !addition.snapshot.changedWhileScanning,
              let file = addition.newMedia, preferences.readAutomatic() == true,
              let options = transfer ?? preferences.read() else { return }
        // Shared queue admission validates metadata/file identity, media type and duplicate identity.
        // The queue's current committed directory remains authoritative at its actor admission turn.
        pending.append(Candidate(info: addition.info, file: file, byDate: options.organizeByDate,
                                 dayKey: dayKey(), deferred: options.deferStart))
        startWorker()
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        guard !closed, preferences.saveAutomatic(enabled) else { return false }
        if !enabled { invalidatePending() }
        return true
    }

    /// Also use after an explicitly confirmed preference recovery. Already-admitted queue tasks
    /// retain Android's normal pause/withdraw semantics; toggling is not a destructive queue action.
    func preferencesDidChange() {
        if preferences.readAutomatic() != true { invalidatePending() }
    }

    @discardableResult
    func resetAfterUserConfirmation() -> Bool {
        guard !closed else { return false }
        invalidatePending()
        return preferences.resetAfterUserConfirmation()
    }

    func close() {
        guard !closed else { return }
        closed = true
        invalidatePending()
    }

    private func invalidatePending() {
        worker?.cancel(); worker = nil; workerToken = nil
        pending.removeAll(); pendingIndex = 0
    }

    private func startWorker() {
        guard !closed, worker == nil, pendingIndex < pending.count else { return }
        let token = UUID(); workerToken = token
        worker = Task { [weak self] in
            while !Task.isCancelled, let self, !self.closed, self.workerToken == token,
                  self.preferences.readAutomatic() == true, self.pendingIndex < self.pending.count {
                let item = self.pending[self.pendingIndex]
                self.pendingIndex += 1
                // enqueueNewMedia checks this task's cancellation at its synchronous actor entry.
                // No await exists between its cancellation/directory checks and shared admission.
                _ = await self.queue.enqueueNewMedia([item.info], files: [item.file], enabled: true,
                    byDate: item.byDate, dayKey: item.dayKey, deferred: item.deferred)
                if self.workerToken == token, self.pendingIndex > 256, self.pendingIndex > self.pending.count / 2 {
                    self.pending.removeFirst(self.pendingIndex); self.pendingIndex = 0
                }
            }
            guard let self, self.workerToken == token else { return }
            self.worker = nil; self.workerToken = nil
            self.pending.removeAll(); self.pendingIndex = 0
        }
    }
}
