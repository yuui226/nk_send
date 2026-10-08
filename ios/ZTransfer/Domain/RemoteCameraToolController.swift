import Foundation

/// RemoteCameraToolPanel's state and protocol lifecycle. The popup owns its
/// closing animation; this object owns polling and drains committed writes.
@MainActor
final class RemoteCameraToolController: ObservableObject, Identifiable {
    let id: UUID
    let tool: RemoteCameraTool
    let movie: Bool
    @Published private(set) var deviceModel: String?
    @Published private(set) var descriptor: RemotePropertyDescriptor?
    @Published private(set) var loading = true
    @Published private(set) var busy = false
    @Published private(set) var pendingValue: UInt64?
    @Published private(set) var errorResource: String?
    @Published private(set) var closeRequested = false
    private(set) var active = true

    private let camera: RemoteCameraControlling
    private let isCurrent: () -> Bool
    private let currentMovie: () -> Bool
    private let canWrite: () -> Bool
    private let beforeWrite: () async -> Bool
    private let onApplied: () async -> Void
    private let onWriteBusyChanged: (Bool) -> Bool
    private let onUnavailable: () -> Void
    private let onDismiss: () -> Void
    private let log: (String) -> Void
    private let readTimeout: Duration
    private let pollInterval: Duration
    private var pollTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var read: RemoteCameraToolRead?

    init(id: UUID = UUID(), camera: RemoteCameraControlling, tool: RemoteCameraTool, movie: Bool,
         isCurrent: @escaping () -> Bool, currentMovie: @escaping () -> Bool,
         canWrite: @escaping () -> Bool, beforeWrite: @escaping () async -> Bool,
         onApplied: @escaping () async -> Void, onUnavailable: @escaping () -> Void,
         onDismiss: @escaping () -> Void, onWriteBusyChanged: @escaping (Bool) -> Bool = { _ in true },
         log: @escaping (String) -> Void = { _ in },
         readTimeout: Duration = .seconds(5), pollInterval: Duration = .milliseconds(1200)) {
        self.id = id
        self.camera = camera; self.tool = tool; self.movie = movie
        self.isCurrent = isCurrent; self.currentMovie = currentMovie; self.canWrite = canWrite
        self.beforeWrite = beforeWrite; self.onApplied = onApplied
        self.onWriteBusyChanged = onWriteBusyChanged
        self.onUnavailable = onUnavailable; self.onDismiss = onDismiss; self.log = log
        self.readTimeout = readTimeout; self.pollInterval = pollInterval
    }

    func start() {
        guard active, pollTask == nil else { return }
        pollTask = Task { [self] in
            deviceModel = await camera.remoteDeviceModel()
            while active && !Task.isCancelled {
                guard isCurrent() else { dismiss(); return }
                if !busy {
                    let operation = RemoteCameraToolRead(camera: camera, tool: tool, movie: movie)
                    read = operation
                    do {
                        let fresh = try await operation.value(timeout: readTimeout)
                        guard active else { return }
                        guard isCurrent() else { dismiss(); return }
                        guard currentMovie() == movie else { dismiss(); return }
                        if loading && (fresh == nil || fresh?.writable != true || fresh?.values.isEmpty == true) {
                            onUnavailable(); dismiss(); return
                        }
                        descriptor = fresh
                    } catch is CancellationError { return }
                    catch {
                        log("!! camera tool read \(tool.rawValue): \(error)")
                        guard active else { return }
                        if loading { onUnavailable(); dismiss(); return }
                    }
                    loading = false
                    // Timeout ends the UI wait, but never overlaps another
                    // descriptor request with an undrained PTP transaction.
                    await operation.drain()
                    if read === operation { read = nil }
                }
                do { try await Task.sleep(for: pollInterval) } catch { return }
            }
        }
    }

    func requestClose() {
        guard active else { return }
        if loading { dismiss() }
        else { closeRequested = true }
    }

    func dismiss() {
        guard active else { return }
        active = false
        pollTask?.cancel()
        onDismiss()
    }

    func select(_ value: UInt64) {
        guard active, !loading, !closeRequested, !busy, canWrite(),
              let previous = descriptor, previous.writable, previous.values.contains(value) else { return }
        if value == previous.current { requestClose(); return }
        guard onWriteBusyChanged(true) else { return }
        busy = true; pendingValue = value; errorResource = nil
        writeTask = Task { [self] in
            var writeAttempted = false
            defer {
                busy = false
                pendingValue = nil
                _ = onWriteBusyChanged(false)
            }
            // Same mutex boundary as Android: finish any poll before checking
            // the physical selector and the current descriptor for this write.
            await read?.drain()
            guard active else { return }
            do {
                guard isCurrent(), canWrite(), currentMovie() == movie else { changed(); return }
                let liveMovie = try await camera.remoteMovieMode()
                guard liveMovie == nil || liveMovie == movie else { changed(); return }
                let fresh = try await camera.remoteCameraTool(tool, movie: movie)
                guard let fresh, fresh.property == previous.property, fresh.writable,
                      fresh.values.contains(value) else {
                    descriptor = fresh; changed(); return
                }
                guard active, isCurrent(), canWrite(), currentMovie() == movie else { changed(); return }
                guard await beforeWrite() else { failed(); return }
                // This unstructured task is deliberately never cancelled by
                // dismissal. Write, finite retries and readback finish together.
                writeAttempted = true
                let result = try await camera.setRemotePropertyVerified(fresh, value: value)
                log(String(format: "camera tool write %@ prop=0x%04X target=%lld confirmed=%@ response=0x%04X",
                           tool.rawValue, fresh.property.rawValue, Int64(bitPattern: value),
                           String(result.confirmed), result.responseCode))
                if isCurrent(), currentMovie() == movie {
                    if let actual = result.actual { descriptor = actual }
                    else { descriptor = try await camera.remoteCameraTool(tool, movie: movie) }
                    if result.confirmed {
                        if tool != .focusMode { await onApplied() }
                        requestClose()
                    } else { failed() }
                }
            } catch is CancellationError { }
            catch {
                failed()
                log("!! camera tool write \(tool.rawValue): \(error)")
            }
            if writeAttempted && tool == .focusMode && isCurrent() && currentMovie() == movie {
                await onApplied()
            }
        }
    }

    func drain() async {
        await writeTask?.value
        await read?.drain()
        await pollTask?.value
    }

    private func changed() { errorResource = "remote_camera_tool_changed" }
    private func failed() { errorResource = "remote_camera_tool_failed" }
}

/// A bounded UI read with separate ownership of the underlying transaction.
/// Cancelling the popup's polling task must not invalidate the shared session.
@MainActor
private final class RemoteCameraToolRead {
    private let camera: RemoteCameraControlling
    private let tool: RemoteCameraTool
    private let movie: Bool
    private var continuation: CheckedContinuation<RemotePropertyDescriptor?, Error>?
    private var operation: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    init(id: UUID = UUID(), camera: RemoteCameraControlling, tool: RemoteCameraTool, movie: Bool) {
        self.camera = camera; self.tool = tool; self.movie = movie
    }

    func value(timeout: Duration) async throws -> RemotePropertyDescriptor? {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            operation = Task { [self] in
                do { finish(.success(try await camera.remoteCameraTool(tool, movie: movie))) }
                catch { finish(.failure(error)) }
            }
            timer = Task { [self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                finish(.success(nil))
            }
        }
    }

    private func finish(_ result: Result<RemotePropertyDescriptor?, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        continuation.resume(with: result)
    }

    func drain() async { await operation?.value }
}
