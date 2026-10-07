import Foundation

/// Request classes used by the Android 1.93 camera scheduler contract.
/// A ticket owns one complete PTP transaction and is never interrupted after admission.
enum CameraRequestKind: Sendable, Equatable {
    case interactive
    case preview
    case transfer
    case rating
    case visibleThumbnail
    case backgroundThumbnail
    case idle
    case eventPoll(background: Bool)

    var priority: Int {
        switch self {
        case .interactive: return 0
        case .preview: return 1
        case .transfer: return 2
        case .rating: return 3
        case .visibleThumbnail: return 4
        case .backgroundThumbnail: return 5
        case .idle: return 6
        case .eventPoll: return 0
        }
    }
}

struct CameraSchedulerSnapshot: Sendable, Equatable {
    let queued: Int
    let activeKind: CameraRequestKind?
    let activeOwner: String
    let interactiveReservations: Int
    let activeDownloads: Int
    let ratingPhaseCount: Int
    let shuttingDown: Bool
}

/// One priority queue for the camera command channel.  The queue controls
/// admission; PTPSession still owns the actual protocol transport.
actor CameraIOGate {
    private final class Ticket: @unchecked Sendable {
        let id = UUID()
        let sequence: UInt64
        let kind: CameraRequestKind
        let owner: String
        let allowDuringShutdown: Bool
        var continuation: CheckedContinuation<Void, any Error>?
        init(sequence: UInt64, kind: CameraRequestKind, owner: String, allowDuringShutdown: Bool) {
            self.sequence = sequence; self.kind = kind; self.owner = owner
            self.allowDuringShutdown = allowDuringShutdown
        }
    }

    private var sequence: UInt64 = 0
    private var pending: [Ticket] = []
    private var active: Ticket?
    private var interactiveReservations = 0
    private var activeDownloads = 0
    private var ratingPhaseCount = 0
    private var shuttingDown = false
    private var shutdownReason = "camera session closed"

    #if STA_GATE_HANDOFF_TESTING
    private var transferHandoffProbe: (@Sendable () async -> Void)?
    func setTransferHandoffProbe(_ probe: @escaping @Sendable () async -> Void) {
        transferHandoffProbe = probe
    }
    #endif

    func snapshot() -> CameraSchedulerSnapshot {
        CameraSchedulerSnapshot(queued: pending.count, activeKind: active?.kind,
                                activeOwner: active?.owner ?? "none",
                                interactiveReservations: interactiveReservations,
                                activeDownloads: activeDownloads,
                                ratingPhaseCount: ratingPhaseCount,
                                shuttingDown: shuttingDown)
    }

    func beginRatingPhase() { ratingPhaseCount += 1; pump() }
    func endRatingPhase() { ratingPhaseCount = max(0, ratingPhaseCount - 1); pump() }

    /// Reject new business work and cancel only tickets that have not entered
    /// the protocol. The active operation remains responsible for its cleanup.
    func beginShutdown(_ reason: String = "camera session closed") {
        shuttingDown = true; shutdownReason = reason
        let queued = pending; pending.removeAll()
        queued.forEach { $0.continuation?.resume(throwing: CancellationError()) }
        pump()
    }

    func withCameraTransaction<T: Sendable>(
        _ kind: CameraRequestKind, owner: String = "camera",
        allowDuringShutdown: Bool = false,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        if shuttingDown && !allowDuringShutdown { throw CancellationError() }
        let ticket = Ticket(sequence: sequence, kind: kind, owner: owner,
                            allowDuringShutdown: allowDuringShutdown)
        sequence &+= 1
        var admitted = false
        defer {
            if admitted { finish(ticket) } else { cancelWaiting(ticket) }
        }
        try await waitForAdmission(ticket)
        admitted = true
        try Task.checkCancellation()
        #if STA_GATE_HANDOFF_TESTING
        if kind == .transfer, let probe = transferHandoffProbe {
            transferHandoffProbe = nil
            await probe()
        }
        #endif
        return try await operation()
    }

    /// Compatibility reservation used across an FHD → EXIF foreground pair.
    /// It reserves priority without holding the protocol channel.
    func withInteractivePriority<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        interactiveReservations += 1; pump()
        defer { interactiveReservations = max(0, interactiveReservations - 1); pump() }
        return try await operation()
    }

    func withInteractive<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await withCameraTransaction(.interactive, owner: "INTERACTIVE", operation)
    }
    func withPreviewTransaction<T: Sendable>(owner: String = "PREVIEW",
                                              _ operation: @Sendable () async throws -> T) async throws -> T {
        try await withCameraTransaction(.preview, owner: owner, operation)
    }
    /// Legacy catalog/metadata path. New callers should choose an explicit kind.
    func withCommand<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await withCameraTransaction(.backgroundThumbnail, owner: "BACKGROUND", operation)
    }
    func withVisibleThumbnail<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await withCameraTransaction(.visibleThumbnail, owner: "VISIBLE_THUMBNAIL", operation)
    }
    func withBackgroundThumbnail<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await withCameraTransaction(.backgroundThumbnail, owner: "BACKGROUND_THUMBNAIL", operation)
    }
    func withRatingTransaction<T: Sendable>(owner: String = "RATING",
                                             _ operation: @Sendable () async throws -> T) async throws -> T {
        try await withCameraTransaction(.rating, owner: owner, operation)
    }
    func withEventPoll<T: Sendable>(background: Bool,
                                    _ operation: @Sendable () async throws -> T) async throws -> T {
        try await withCameraTransaction(.eventPoll(background: background),
                                        owner: background ? "EVENT_POLL_BACKGROUND" : "EVENT_POLL_INTERACTIVE",
                                        operation)
    }
    func withTransferSlice<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await withCameraTransaction(.transfer, owner: "TRANSFER", operation)
    }

    func withDownloadActivity<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        activeDownloads += 1; pump()
        defer { activeDownloads = max(0, activeDownloads - 1); pump() }
        return try await operation()
    }

    func withIdleCommand<T: Sendable>(skippedValue: T,
                                      _ operation: @Sendable () async throws -> T) async throws -> T {
        guard activeDownloads == 0 else { return skippedValue }
        return try await withCameraTransaction(.idle, owner: "IDLE") {
            guard await !self.downloadIsActive() else { return skippedValue }
            return try await operation()
        }
    }

    private func downloadIsActive() -> Bool { activeDownloads > 0 }

    private func waitForAdmission(_ ticket: Ticket) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                ticket.continuation = continuation
                pending.append(ticket); pump()
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancelWaiting(ticket) }
        }
    }

    private func cancelWaiting(_ ticket: Ticket) {
        guard let index = pending.firstIndex(where: { $0.id == ticket.id }) else { return }
        pending.remove(at: index)
        ticket.continuation?.resume(throwing: CancellationError()); ticket.continuation = nil
        pump()
    }

    private func finish(_ ticket: Ticket) {
        if active?.id == ticket.id { active = nil; pump() }
        else { cancelWaiting(ticket) }
    }

    private func eligible(_ ticket: Ticket) -> Bool {
        // `withIdleCommand` performs the first activity check before creating
        // this ticket and a second check after admission. Do not screen the
        // ticket here: if a download starts while the idle request is queued,
        // it must be admitted and return its skipped value instead of waiting
        // forever for the download to finish.
        if interactiveReservations > 0, ticket.kind.priority > CameraRequestKind.preview.priority { return false }
        if ratingPhaseCount > 0 {
            switch ticket.kind {
            case .visibleThumbnail, .backgroundThumbnail, .idle: return false
            case .eventPoll(background: true): return false
            default: break
            }
        }
        return !shuttingDown || ticket.allowDuringShutdown
    }

    private func effectivePriority(_ kind: CameraRequestKind) -> Int {
        if case .eventPoll(background: true) = kind {
            return ratingPhaseCount > 0 ? CameraRequestKind.idle.priority : CameraRequestKind.transfer.priority
        }
        return kind.priority
    }

    private func pump() {
        guard active == nil,
              let selected = pending.filter(eligible).min(by: {
                  let left = effectivePriority($0.kind), right = effectivePriority($1.kind)
                  return left == right ? $0.sequence < $1.sequence : left < right
              }) else { return }
        pending.removeAll { $0.id == selected.id }; active = selected
        selected.continuation?.resume(); selected.continuation = nil
    }
}
