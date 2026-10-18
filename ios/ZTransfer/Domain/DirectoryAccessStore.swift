import Foundation
import SwiftUI
import UIKit

/// A successful start is balanced exactly once, when the last task holding
/// this lease ends. Sharing the lease does not depend on the selected folder.
struct DirectoryAccessOperations: Sendable {
    let start: @Sendable (URL) -> Bool
    let stop: @Sendable (URL) -> Void
    static let system = DirectoryAccessOperations(
        start: { $0.startAccessingSecurityScopedResource() },
        stop: { $0.stopAccessingSecurityScopedResource() }
    )
}

final class DirectoryAccessLease: Sendable {
    let url: URL
    let isSecurityScoped: Bool
    private let operations: DirectoryAccessOperations

    init(url: URL, operations: DirectoryAccessOperations = .system) {
        self.url = url
        self.operations = operations
        isSecurityScoped = operations.start(url)
    }

    deinit {
        if isSecurityScoped { operations.stop(url) }
    }
}

/// Android primeDirectoryIndexScan/getDirectoryIndex share startup work.
/// Registration happens before exposing a restored URL; a queue also claims
/// roots without cleanup so a later store restore cannot sweep active work.
final class TransferDirectoryPreparation: @unchecked Sendable {
    static let shared = TransferDirectoryPreparation()
    typealias Cleanup = @Sendable (URL) async -> Void
    private enum State { case cleaning(Task<Void, Never>), ready }
    private let lock = NSLock()
    private var states: [URL: State] = [:]
    private let cleanup: Cleanup
    private var waiting = 0
    var pendingWaiterCount: Int { lock.withLock { waiting } }

    init(cleanup: @escaping Cleanup = { _ = TransferDirectoryIndex.removeStaleTemporaryFiles(in: $0) }) {
        self.cleanup = cleanup
    }

    private func key(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }

    func beginCleanup(access: DirectoryAccessLease, resolvedKey: URL? = nil) {
        let root = resolvedKey ?? key(access.url)
        lock.withLock {
            guard states[root] == nil else { return }
            let cleanup = cleanup
            states[root] = .cleaning(Task.detached(priority: .utility) { [weak self] in
                defer { withExtendedLifetime(access) {} }
                await cleanup(access.url)
                self?.didFinish(root)
            })
        }
    }

    private func didFinish(_ root: URL) {
        lock.withLock { states[root] = .ready }
    }

    func waitUntilReady(_ url: URL) async throws {
        try Task.checkCancellation()
        let root = key(url)
        let task: Task<Void, Never>? = lock.withLock {
            if case let .cleaning(task) = states[root] {
                waiting += 1
                return task
            }
            states[root] = .ready
            return nil
        }
        guard let task else { return }
        defer { lock.withLock { waiting -= 1 } }
        let waiter = DirectoryPreparationWaiter()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                Task {
                    await task.value
                    waiter.finish(.success(()))
                }
            }
        } onCancel: {
            waiter.finish(.failure(CancellationError()))
        }
        try Task.checkCancellation()
    }
}

/// Cancellation releases only this waiter. Startup cleanup remains shared by
/// other queues and keeps its own directory lease until the filesystem work ends.
private final class DirectoryPreparationWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, any Error>?
    private var continuation: CheckedContinuation<Void, any Error>?

    func install(_ continuation: CheckedContinuation<Void, any Error>) {
        let completed: Result<Void, any Error>? = lock.withLock {
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let completed { continuation.resume(with: completed) }
    }

    func finish(_ result: Result<Void, any Error>) {
        let pending: CheckedContinuation<Void, any Error>? = lock.withLock {
            guard self.result == nil else { return nil }
            self.result = result
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }
}

@MainActor
final class DirectoryAccessStore: ObservableObject {
    @Published private(set) var directoryURL: URL?
    @Published private(set) var isRestoring = false
    private let defaults: UserDefaults
    private let accessOperations: DirectoryAccessOperations
    private let preparation: TransferDirectoryPreparation
    private let makeBookmark: @Sendable (URL) throws -> Data
    private let resolveBookmark: @Sendable (Data) throws -> ResolvedBookmark
    private var directoryAccess: DirectoryAccessLease?
    private var selectionTask: Task<Void, Never>?
    private var selectionID = UUID()
    private var pendingURL: URL?
    private var restorationWaiters: [UUID: DirectoryPreparationWaiter] = [:]
    // Android persists this setting under ztransfer/transfer_dir.  The value
    // is platform-specific (bookmark bytes on iOS, URI text on Android), but
    // the preference identity remains identical.
    private let bookmarkKey = "transfer_dir"

    init(defaults: UserDefaults = .standard, accessOperations: DirectoryAccessOperations = .system,
         preparation: TransferDirectoryPreparation = .shared,
         makeBookmark: @escaping @Sendable (URL) throws -> Data = {
             try $0.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
         }, resolveBookmark: @escaping @Sendable (Data) throws -> ResolvedBookmark = ResolvedBookmark.resolve) {
        self.defaults = defaults
        self.accessOperations = accessOperations
        self.preparation = preparation
        self.makeBookmark = makeBookmark
        self.resolveBookmark = resolveBookmark
        restore()
    }

    struct ResolvedBookmark: Sendable {
        let url: URL
        let stale: Bool
        nonisolated static func resolve(_ data: Data) throws -> Self {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            return .init(url: url, stale: stale)
        }
    }

    /// The root waits before starting connection discovery. Cancellation only
    /// removes this waiter; it cannot cancel the app-owned restoration.
    func waitUntilRestored() async throws {
        try Task.checkCancellation()
        guard isRestoring else { return }
        let id = UUID(), waiter = DirectoryPreparationWaiter()
        restorationWaiters[id] = waiter
        defer { restorationWaiters.removeValue(forKey: id) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter.install($0) }
        } onCancel: { waiter.finish(.failure(CancellationError())) }
        try Task.checkCancellation()
    }

    private func finishRestoration() {
        guard isRestoring else { return }
        isRestoring = false
        let pending = restorationWaiters.values
        restorationWaiters.removeAll()
        for waiter in pending { waiter.finish(.success(())) }
    }

    /// Android setTransferDirUri publishes only after the grant is retained.
    /// A document provider may block both grant acquisition and bookmark creation;
    /// keep them off MainActor and commit together, without releasing old workers'
    /// leases. A replaced/cleared selection must never publish its late result.
    @discardableResult
    func setDirectory(_ url: URL) -> Task<Void, Never> {
        if pendingURL == url, let selectionTask { return selectionTask }
        selectionTask?.cancel()
        let id = UUID()
        selectionID = id
        pendingURL = url
        let operations = accessOperations, makeBookmark = makeBookmark
        let worker = Task.detached(priority: .userInitiated) { () -> PreparedSelection? in
            do {
                try Task.checkCancellation()
                let access = DirectoryAccessLease(url: url, operations: operations)
                guard access.isSecurityScoped else { return nil }
                try Task.checkCancellation()
                // iOS document-provider bookmarks carry the acquired grant.
                // macOS's withSecurityScope option is unavailable here.
                let bookmark = try makeBookmark(url)
                try Task.checkCancellation()
                return PreparedSelection(access: access, bookmark: bookmark, cleanupKey: nil)
            } catch { return nil }
        }
        return accept(worker, id: id)
    }

    private func accept(_ worker: Task<PreparedSelection?, Never>, id: UUID) -> Task<Void, Never> {
        let task = Task { [weak self] in
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard let self, self.selectionID == id else { return }
            self.selectionTask = nil
            self.pendingURL = nil
            guard !Task.isCancelled else {
                // If an explicit selection superseded startup and was then
                // cancelled, the saved startup grant must still be restored.
                if self.isRestoring { self.restore() }
                return
            }
            if let result {
                if result.cleanupKey == nil || self.defaults.data(forKey: self.bookmarkKey) != result.bookmark {
                    self.defaults.set(result.bookmark, forKey: self.bookmarkKey)
                }
                self.directoryAccess = result.access
                if let key = result.cleanupKey {
                    // Register before releasing startup waiters or exposing the
                    // URL; cleanup itself runs independently in the background.
                    self.preparation.beginCleanup(access: result.access, resolvedKey: key)
                }
                if self.directoryURL != result.access.url { self.directoryURL = result.access.url }
            } else {
                self.removeSelection()
            }
            self.finishRestoration()
        }
        selectionTask = task
        return task
    }

    func clear() {
        selectionID = UUID()
        selectionTask?.cancel()
        selectionTask = nil
        pendingURL = nil
        removeSelection()
        finishRestoration()
    }

    private struct PreparedSelection: Sendable {
        let access: DirectoryAccessLease
        let bookmark: Data
        let cleanupKey: URL?
    }

    private func removeSelection() {
        directoryAccess = nil
        if directoryURL != nil { directoryURL = nil }
        defaults.removeObject(forKey: bookmarkKey)
    }

    deinit { selectionTask?.cancel() }

    private func restore() {
        guard let data = defaults.data(forKey: bookmarkKey) else { finishRestoration(); return }
        if !isRestoring { isRestoring = true }
        let id = UUID()
        selectionID = id
        let resolve = resolveBookmark, make = makeBookmark, operations = accessOperations
        let worker = Task.detached(priority: .userInitiated) { () -> PreparedSelection? in
            do {
                try Task.checkCancellation()
                let resolved = try resolve(data)
                try Task.checkCancellation()
                let access = DirectoryAccessLease(url: resolved.url, operations: operations)
                guard access.isSecurityScoped else { return nil }
                try Task.checkCancellation()
                let bookmark = resolved.stale ? ((try? make(resolved.url)) ?? data) : data
                let key = resolved.url.resolvingSymlinksInPath().standardizedFileURL
                try Task.checkCancellation()
                return PreparedSelection(access: access, bookmark: bookmark, cleanupKey: key)
            } catch { return nil }
        }
        _ = accept(worker, id: id)
    }
}

struct DirectoryPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {
        context.coordinator.onPick = onPick
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onPick: (URL) -> Void
        private var finished = false
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !finished, let url = urls.first else { return }
            finished = true
            onPick(url)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finished = true }
    }
}
