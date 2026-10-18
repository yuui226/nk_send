#if DEBUG
import SwiftUI

/// F077 exercises production cards against real failed tasks and disk indexing.
struct QueueRetryInteractionHarness: View {
    private let queue: TransferQueue
    private let root: URL
    private let session: CameraSession?
    @StateObject private var model: TransferQueueViewModel
    @StateObject private var originals: PhotoListViewModel
    @StateObject private var directory: DirectoryAccessStore
    private let clearCamera = QueueClearFailureCamera()
    @ObservedObject private var clearTrace = QueueClearInteractionTrace.shared
    @ObservedObject private var animationTrace = QueueConfirmationAnimationTrace.shared
    private let clearTest = ProcessInfo.processInfo.arguments.contains("--queue-clear-window-test")
    @State private var controlNonce: UInt64 = 0
    @State private var connected = false
    @State private var loaded = false
    @State private var fixtureError = ""

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("queue-retry-\(UUID())")
        let access = DirectoryAccessOperations(start: { _ in true }, stop: { _ in })
        let queue = TransferQueue(defaults: UserDefaults(suiteName: "QueueRetryHarness.queue")!, accessOperations: access)
        self.queue = queue
        _model = StateObject(wrappedValue: TransferQueueViewModel(queue: queue))
        _originals = StateObject(wrappedValue: PhotoListViewModel(scanCatalog: nil, setRemoteGate: { _ in }))
        _directory = StateObject(wrappedValue: DirectoryAccessStore(
            defaults: UserDefaults(suiteName: "QueueRetryHarness.directory")!, accessOperations: access))
        session = ProcessInfo.processInfo.arguments.contains("--retry-no-session") ? nil
            : CameraSession(repository: CameraRepository(debugData: .shared))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("First local") { addLocal([1]) }.accessibilityIdentifier("retry-local-first")
                Button("Both local") { addLocal([1, 2]) }.accessibilityIdentifier("retry-local-both")
                Button(connected ? "Disconnect" : "Connect") { connected.toggle() }
                    .accessibilityIdentifier("retry-connection")
            }.font(.system(size: 12))
            Text("failed=\(model.snapshot.items.filter { $0.status == .failed }.count);done=\(model.snapshot.items.filter { $0.status == .completed }.count)")
                .accessibilityIdentifier("retry-fixture-state")
            if clearTest {
                Text(clearTrace.report).accessibilityIdentifier("queue-clear-trace")
                Text(model.snapshot.items.contains { $0.file.id == 2 && $0.status == .transferring } ? "active" : "idle")
                    .accessibilityIdentifier("queue-clear-active")
            }
            if ProcessInfo.processInfo.arguments.contains("--queue-confirmation-test") {
                HStack {
                    Button("Control event") { controlNonce &+= 1 }
                        .accessibilityIdentifier("queue-test-control")
                    Button("Remove eligible") {
                        Task { await queue.clearFinished() }
                    }.accessibilityIdentifier("queue-test-remove")
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--queue-confirmation-activity-test") {
                Button("Start new transfer") {
                    Task {
                        _ = await queue.enqueue([CameraFile(id: 3, storageID: 1, format: 0x3801, size: 10,
                            fileName: "RETRY_3.JPG", captureDate: nil, isProtected: false)])
                        await queue.start(session: QueueConfirmationBusyCamera(), directory: root)
                    }
                }.accessibilityIdentifier("queue-test-start-new")
                Text(model.snapshot.isTransferring ? "running" : "idle")
                    .accessibilityIdentifier("queue-test-activity")
            }
            if QueueConfirmationAnimationTrace.enabled {
                Text("toggles=\(animationTrace.toggles)").accessibilityIdentifier("queue-confirmation-toggles")
                Text(animationTrace.report).accessibilityIdentifier("queue-confirmation-animation")
                Text("mounts=\(animationTrace.mounts)").accessibilityIdentifier("queue-confirmation-mounts")
            }
            if !fixtureError.isEmpty { Text(fixtureError) }
            TransferQueueView(model: model, session: session, directory: directory,
                isSessionConnected: connected, showsTopControls: false,
                controlActionNonce: controlNonce,
                hasIndexedOriginal: { item in
                    originals.hasTransferredOriginal(item.file, folderName: item.destinationFolderName,
                                                     directory: directory.directoryURL)
                }, onNavigateBack: {})
        }
        .task {
            guard !loaded else { return }
            loaded = true
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                await directory.setDirectory(root).value
                originals.refreshTransferredIDs(directory: root, storageMode: .unified)
                let count = ProcessInfo.processInfo.arguments.contains("--queue-confirmation-scroll-test") ? 12 : 2
                _ = await queue.enqueue((1...count).map { id in
                    CameraFile(id: UInt32(id), storageID: 1, format: 0x3801, size: 10,
                               fileName: fixtureName(id), captureDate: nil, isProtected: false)
                })
                if clearTest {
                    clearTrace.reset {
                        Task {
                            try? await Task.sleep(for: .milliseconds(60))
                            await clearCamera.fail()
                        }
                    }
                    await queue.start(session: clearCamera, directory: root)
                } else {
                    await queue.start(session: QueueRetryFailureCamera(), directory: root)
                }
            } catch { fixtureError = error.localizedDescription }
        }
    }
    private func fixtureName(_ id: Int) -> String {
        ProcessInfo.processInfo.arguments.contains("--queue-long-title-test")
            ? "A_VERY_LONG_CAMERA_CAPTURE_FILENAME_123456_\(id).JPG" : "RETRY_\(id).JPG"
    }
    private func addLocal(_ ids: [Int]) {
        do {
            for id in ids { try Data(repeating: 1, count: 10).write(to: root.appendingPathComponent(fixtureName(id))) }
            originals.refreshTransferredIDs(directory: root, storageMode: .unified)
        } catch { fixtureError = error.localizedDescription }
    }
}

private struct QueueConfirmationBusyCamera: TransferDownloading {
    func download(file: CameraFile, to directory: URL,
                  progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        try await Task.sleep(for: .seconds(60))
        throw CameraTransportError.unavailable
    }
}

private struct QueueRetryFailureCamera: TransferDownloading {
    func download(file: CameraFile, to directory: URL,
                  progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        throw CameraTransportError.unavailable
    }
}
private actor QueueClearFailureCamera: TransferDownloading {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func download(file: CameraFile, to directory: URL,
                  progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        if file.id == 2, !released {
            await withCheckedContinuation { continuation = $0 }
        }
        throw CameraTransportError.unavailable
    }
    func fail() {
        released = true
        continuation?.resume(); continuation = nil
    }
}

/// DEBUG event recorder for the actual production card's mounted buttons.
/// It observes the real 320ms cleanup; it never changes that timing or policy.
@MainActor
final class QueueClearInteractionTrace: ObservableObject {
    static let shared = QueueClearInteractionTrace()
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--queue-clear-window-test") }
    @Published private(set) var report = "late=false;leaked=false;finished=false"
    private var clearing = false
    private var late = false
    private var leaked = false
    private var finished = false
    private var onBegin: (() -> Void)?
    func reset(onBegin: @escaping () -> Void) {
        clearing = false; late = false; leaked = false; finished = false
        self.onBegin = onBegin; publish()
    }
    func clearingChanged(_ value: Bool) {
        guard Self.enabled else { return }
        clearing = value
        if value { onBegin?() } else { finished = true }
        publish()
    }
    func snapshotChanged(_ items: [TransferQueueItem]) {
        guard Self.enabled, clearing else { return }
        if items.contains(where: { $0.file.id == 2 && $0.status == .failed }) { late = true; publish() }
    }
    func actionAppeared(fileID: UInt32) {
        guard Self.enabled, clearing, fileID == 2 else { return }
        leaked = true; publish()
    }
    private func publish() { report = "late=\(late);leaked=\(leaked);finished=\(finished)" }
}
/// Observe actual Genie callbacks; never shorten or replace production timing.
@MainActor
final class QueueConfirmationAnimationTrace: ObservableObject {
    static let shared = QueueConfirmationAnimationTrace()
    static var frameReversal: Bool { ProcessInfo.processInfo.arguments.contains("--queue-confirmation-frame-reversal-test") }
    static var enabled: Bool { frameReversal || ProcessInfo.processInfo.arguments.contains("--queue-confirmation-reversal-test") }
    @Published private(set) var report = "closing=false;reversed=false;zero=false"
    @Published private(set) var toggles = 0
    @Published private(set) var mounts = 0
    private var reopen: (() -> Void)?
    private var triggered = false
    func panelAppeared() { if Self.enabled { mounts += 1 } }
    func toggle(closing: Bool, reopen: @escaping () -> Void) {
        guard Self.enabled else { return }
        toggles += 1
        if closing && Self.frameReversal && !triggered { self.reopen = reopen }
    }
    private var closing = false
    private var reversed = false
    private var reachedZero = false
    func record(_ progress: CGFloat, expanded: Bool) {
        guard Self.enabled else { return }
        if progress > 0 && progress < 1 {
            if !expanded { closing = true }
            if expanded && closing { reversed = true }
        }
        if closing && !reversed && progress == 0 { reachedZero = true }
        let next = "closing=\(closing);reversed=\(reversed);zero=\(reachedZero)"
        if report != next { report = next }
        // Trigger only after the renderer supplied a real closing frame.
        // This changes no clock, curve, duration, or rendering implementation.
        if !expanded && progress > 0 && progress < 0.8, let reopen, !triggered {
            triggered = true
            self.reopen = nil
            reopen()
        }
    }
}
#endif
