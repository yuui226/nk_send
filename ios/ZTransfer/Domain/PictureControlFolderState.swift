import Foundation
import Combine

enum PictureControlImportFailure: Error { case read, invalid, flexibleColor, unsupported, timeout }

/// Android PictureControlFolderState: browsing is metadata-only; reading never writes a camera.
/// Security-scoped bookmarks are independent per owner and every acquisition is balanced locally.
@MainActor
final class PictureControlFolderState: ObservableObject {
    @Published private(set) var folder: URL?
    @Published private(set) var files: [PresetFile] = []
    @Published private(set) var failure: RemoteLUTFolderAccessError?
    @Published private(set) var scanning = false
    @Published private(set) var hasSnapshot = false
    var onNotice: (String) -> Void = { _ in }
    private let access: RemoteLUTFolderAccess
    private let request: LUTRequestController
    private let queue: PresetIOQueue
    private let timeout: Duration
    private var closed = false
    private let scan: @Sendable (URL?, Data?, PresetIOQueue.Ticket) throws -> RemoteLUTFolderAccess.PreparedFolder

    init(defaults: UserDefaults = .standard, queue: PresetIOQueue = .shared,
         timeout: Duration = .seconds(10),
         scan: @escaping @Sendable (URL?, Data?, PresetIOQueue.Ticket) throws -> RemoteLUTFolderAccess.PreparedFolder = { replacement, bookmark, ticket in
             if let replacement {
                 return try RemoteLUTFolderAccess.prepareFolder(replacement, fileExtension: "np3", checkCancelled: ticket.checkCancellation)
             }
             return try RemoteLUTFolderAccess.prepareBookmark(bookmark, fileExtension: "np3", checkCancelled: ticket.checkCancellation)
         }) {
        access = RemoteLUTFolderAccess(defaults: defaults, scope: .pictureControl)
        folder = access.resolve()
        self.queue = queue; self.timeout = timeout; self.scan = scan
        request = LUTRequestController(queue: queue)
    }
    // A provider may be unavailable during launch while its bookmark remains
    // valid. Keep retrying the saved grant instead of silently losing the folder.
    func refresh() { if !scanning, folder != nil || access.bookmarkData != nil { startScan(nil) } }
    func changeFolder(_ url: URL) { startScan(url) }
    private func startScan(_ replacement: URL?) {
        guard !closed else { return }
        scanning = true
        let bookmark = access.bookmarkData, scan = scan
        request.submit(timeout: timeout, action: { try scan(replacement, bookmark, $0) }, onTimeout: { [weak self] in
            guard let self else { return }
            self.scanning = false
            if replacement == nil { self.failure = .read }
            self.onNotice("picture_control_read_timeout")
        }, deliver: { [weak self] result in
            guard let self, !self.closed else { return }
            self.scanning = false
            switch result {
            case .success(let snapshot):
                self.access.commit(snapshot)
                self.folder = replacement ?? RemoteLUTFolderAccess.resolveBookmark(snapshot.bookmark) ?? self.folder
                self.files = snapshot.files; self.failure = nil; self.hasSnapshot = true
            case .failure(let error):
                let reason = error as? RemoteLUTFolderAccessError ?? .read
                if replacement == nil { self.failure = reason }
                else { self.onNotice(Self.message(reason)) }
            }
        })
    }
    static func message(_ reason: RemoteLUTFolderAccessError) -> String {
        switch reason {
        case .missing: "lut_folder_missing"
        case .denied: "lut_folder_denied"
        case .read: "lut_folder_read_failed"
        case .tooMany: "lut_folder_too_many"
        }
    }
    func read(_ file: PresetFile) async throws -> NikonPictureControlFile {
        let bookmark = access.bookmarkData
        let read = PresetAsyncRead<NikonPictureControlFile>(queue: queue, timeout: timeout)
        return try await read.perform { ticket in
            let parsed: NikonPictureControlFile
            do {
                parsed = try RemoteLUTFolderAccess.withScopedFile(bookmark, file: file, checkCancelled: ticket.checkCancellation) { url in
                    guard let stream = InputStream(url: url) else { throw PictureControlImportFailure.read }
                    stream.open(); defer { stream.close() }
                    return try NikonPictureControlFile.read(stream, checkpoint: ticket.checkCancellation)
                }
            } catch NikonPictureControlError.flexibleColorUnsupported { throw PictureControlImportFailure.flexibleColor }
            catch is NikonPictureControlError { throw PictureControlImportFailure.invalid }
            catch is CancellationError { throw CancellationError() }
            catch { throw PictureControlImportFailure.read }
            do { _ = try parsed.encodeClassicPictureControl() }
            catch { throw PictureControlImportFailure.unsupported }
            return parsed
        }
    }
    func close() { closed = true; request.cancel(); scanning = false }
}

/// Resumes the caller promptly on cancellation/timeout even if a provider ignores cancellation.
/// The shared worker still drains that accepted read before starting the next request.
@MainActor
final class PresetAsyncRead<Value: Sendable> {
    private let queue: PresetIOQueue
    private let timeout: Duration
    private var continuation: CheckedContinuation<Value, Error>?
    private var ticket: PresetIOQueue.Ticket?
    private var timer: Task<Void, Never>?
    init(queue: PresetIOQueue, timeout: Duration) { self.queue = queue; self.timeout = timeout }
    func perform(_ action: @escaping @Sendable (PresetIOQueue.Ticket) throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                ticket = queue.submit(action: action) { [self] in finish($0) }
                timer = Task { [self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    finish(.failure(PictureControlImportFailure.timeout))
                }
            }
        } onCancel: { Task { @MainActor [self] in finish(.failure(CancellationError())) } }
    }
    private func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        ticket?.cancel(); ticket = nil; timer?.cancel(); timer = nil
        continuation.resume(with: result)
    }
}
