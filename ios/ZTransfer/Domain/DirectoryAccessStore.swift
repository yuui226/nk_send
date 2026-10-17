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

    func beginCleanup(access: DirectoryAccessLease) {
        let root = key(access.url)
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
    private let defaults: UserDefaults
    private let accessOperations: DirectoryAccessOperations
    private let preparation: TransferDirectoryPreparation
    private var directoryAccess: DirectoryAccessLease?
    // Android persists this setting under ztransfer/transfer_dir.  The value
    // is platform-specific (bookmark bytes on iOS, URI text on Android), but
    // the preference identity remains identical.
    private let bookmarkKey = "transfer_dir"

    init(defaults: UserDefaults = .standard, accessOperations: DirectoryAccessOperations = .system,
         preparation: TransferDirectoryPreparation = .shared) {
        self.defaults = defaults
        self.accessOperations = accessOperations
        self.preparation = preparation
        restore()
    }

    func setDirectory(_ url: URL) {
        let access = DirectoryAccessLease(url: url, operations: accessOperations)
        guard access.isSecurityScoped else {
            directoryAccess = nil
            directoryURL = nil
            defaults.removeObject(forKey: bookmarkKey)
            return
        }
        do {
            let bookmark = try url.bookmarkData(
                // iOS document-provider URLs carry their security scope in the
                // bookmark; the macOS-only withSecurityScope creation option is
                // unavailable on iOS.
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil,
            )
            defaults.set(bookmark, forKey: bookmarkKey)
            directoryAccess = access
            directoryURL = url
        } catch {
            directoryAccess = nil
            directoryURL = nil
            defaults.removeObject(forKey: bookmarkKey)
        }
    }

    func clear() {
        directoryAccess = nil
        directoryURL = nil
        defaults.removeObject(forKey: bookmarkKey)
    }

    private func restore() {
        guard let data = defaults.data(forKey: bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale,
        ) else {
            defaults.removeObject(forKey: bookmarkKey)
            return
        }
        let access = DirectoryAccessLease(url: url, operations: accessOperations)
        guard access.isSecurityScoped else {
            defaults.removeObject(forKey: bookmarkKey)
            return
        }
        directoryAccess = access
        if stale, let refreshed = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil,
        ) { defaults.set(refreshed, forKey: bookmarkKey) }
        // Register synchronously before observers can enqueue into this root.
        preparation.beginCleanup(access: access)
        directoryURL = url
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
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { if let url = urls.first { onPick(url) } }
    }
}
