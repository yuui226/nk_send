import Foundation

/// Scheduling boundary equivalent to Android's `CameraIoGate`.
///
/// PTPSession serializes commands, but FIFO alone is insufficient for the
/// camera workflow: a foreground FHD/EXIF request registered between two
/// download chunks must get the next transaction, while an idle probe must be
/// skipped during the whole download. This gate owns those two policies and
/// deliberately leaves the PTP transaction itself owned by PTPSession.
actor CameraIOGate {
    private enum Kind: Sendable {
        case ordinary
        case transfer
    }

    private struct Waiter {
        let id: UUID
        let kind: Kind
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var locked = false
    private var waiters: [Waiter] = []
    /// Reservations remain held across the FHD/EXIF pair. A transfer slice
    /// may therefore finish, but the next slice cannot begin until the whole
    /// foreground operation has released its reservation.
    private var interactiveReservations = 0
    private var activeDownloads = 0

    #if STA_GATE_HANDOFF_TESTING
    // Host regression barrier only; this flag is never enabled in the app.
    // Pause after a grant to reproduce another actor job registering priority
    // before the granted transfer resumes. No timing sleeps are required.
    private var transferHandoffProbe: (@Sendable () async -> Void)?
    func setTransferHandoffProbe(_ probe: @escaping @Sendable () async -> Void) {
        transferHandoffProbe = probe
    }
    #endif

    func withInteractivePriority<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        interactiveReservations += 1
        defer {
            interactiveReservations = max(0, interactiveReservations - 1)
            serviceNextWaiter()
        }
        return try await operation()
    }

    func withInteractive<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await withInteractivePriority {
            try await self.withCommand(operation)
        }
    }

    /// Android's ordinary ioMutex path: thumbnails and catalog reads share
    /// FIFO lock ordering with FHD/EXIF; only download slices yield to a
    /// registered interactive reservation.
    func withCommand<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await withLock(kind: .ordinary, operation)
    }

    func withTransferSlice<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await withLock(kind: .transfer, operation)
    }

    func withDownloadActivity<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        activeDownloads += 1
        defer {
            activeDownloads = max(0, activeDownloads - 1)
            serviceNextWaiter()
        }
        return try await operation()
    }

    /// Android's idle command checks the whole-download activity both before
    /// queueing and after taking the mutex. The second check closes the race
    /// where a download starts while the idle probe is waiting for a slice.
    func withIdleCommand<T: Sendable>(
        skippedValue: T,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        guard activeDownloads == 0 else { return skippedValue }
        try await acquire(kind: .ordinary)
        defer { release() }
        try Task.checkCancellation()
        guard activeDownloads == 0 else { return skippedValue }
        return try await operation()
    }

    private func withLock<T: Sendable>(
        kind: Kind,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        while true {
            try await acquire(kind: kind)
            defer { release() }
            #if STA_GATE_HANDOFF_TESTING
            if kind == .transfer, let probe = transferHandoffProbe {
                transferHandoffProbe = nil
                await probe()
            }
            #endif
            try Task.checkCancellation()
            // NikonCamera.CameraIoGate checks priority again AFTER mutex.lock.
            // acquire may suspend: a reservation can arrive after the grant
            // but before this actor continuation resumes. Return the grant
            // and wait for that reservation rather than starting a new slice.
            if kind == .transfer && interactiveReservations > 0 { continue }
            return try await operation()
        }
    }

    private func acquire(kind: Kind) async throws {
        try Task.checkCancellation()
        let id = UUID()
        if canStart(kind: kind) {
            locked = true
            return
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, kind: kind, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func canStart(kind: Kind) -> Bool {
        guard !locked else { return false }
        switch kind {
        case .transfer:
            return interactiveReservations == 0
        case .ordinary:
            return true
        }
    }

    private func serviceNextWaiter() {
        guard !locked else { return }
        let index = waiters.firstIndex { canStart(kind: $0.kind) }
        guard let index else { return }
        let waiter = waiters.remove(at: index)
        locked = true
        waiter.continuation.resume()
    }

    private func release() {
        guard locked else { return }
        locked = false
        serviceNextWaiter()
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
        serviceNextWaiter()
    }
}
