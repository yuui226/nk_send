#if DEBUG
import SwiftUI

/// The real list, preview, admission checks and queue; only catalog/transport
/// and directory permission operations are fixtures. Preferences are isolated.
struct PhotoListAdmissionHarness: View {
    private let session = CameraSession(repository: CameraRepository(debugData: .shared))
    private let model: PhotoListViewModel
    private let queue: TransferQueue
    private let directory: DirectoryAccessStore
    private let effects: PhotoEffectsStore
    private let defaults: UserDefaults
    @StateObject private var observer: TransferQueueViewModel
    @State private var connected = false
    @State private var trace = "[]"
    private let tracesHold = ProcessInfo.processInfo.arguments.contains("--photo-hold-trace")

    init() {
        // A disconnected production model is terminal; timing tests need a
        // connected catalog from the first render, not reuse a retired one.
        _connected = State(initialValue: tracesHold)
        let suite = "PhotoListAdmissionUITest"
        let preferences = UserDefaults(suiteName: suite)!
        preferences.removePersistentDomain(forName: suite)
        preferences.set(ProcessInfo.processInfo.arguments.contains("--defer-admission"), forKey: "defer_transfer_start")
        preferences.set(ProcessInfo.processInfo.arguments.contains("--preview-admission"), forKey: "tap_to_preview")
        preferences.set(3, forKey: "thumbnail_columns")
        let burst = ProcessInfo.processInfo.arguments.contains("--burst-admission")
        preferences.set(burst, forKey: "collapse_burst_photos")
        preferences.set(TransferStorageMode.unified.rawValue, forKey: TransferStorageMode.persistenceKey)
        defaults = preferences
        let lastID = ProcessInfo.processInfo.arguments.contains("--scroll-hold-fixture") ? 760 : burst ? 703 : 702
        let files = (701...lastID).map { id in
            CameraFile(id: UInt32(id), storageID: 1, format: 0x3801, size: 10,
                fileName: String(format: "DSC_%04d.JPG", id),
                captureDate: burst || id == 701 ? "20261016T100000" : "20261016T110000", isProtected: false)
        }
        model = PhotoListViewModel(scanCatalog: { _, _, _, _, batch in
            try await batch(files)
            return PhotoScanResult(files: files, removedHandles: [], addedHandles: [],
                handleQueriesSucceeded: true, metadataComplete: true)
        }, setRemoteGate: { _ in })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("list-admission-\(UUID())")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originals = ProcessInfo.processInfo.arguments.contains("--all-local-admission") ? files : [files[0]]
        for original in originals {
            try! Data(repeating: 1, count: 10).write(to: root.appendingPathComponent(original.fileName))
        }
        let operations = DirectoryAccessOperations(start: { _ in true }, stop: { _ in })
        directory = DirectoryAccessStore(defaults: preferences, accessOperations: operations)
        directory.setDirectory(root)
        effects = PhotoEffectsStore(defaults: preferences)
        let transferQueue = TransferQueue(premiumAccess: PremiumAccess(.lifetime), accessOperations: operations)
        queue = transferQueue
        _observer = StateObject(wrappedValue: TransferQueueViewModel(queue: transferQueue))
    }
    var body: some View {
        PhotoListView(session: session, listModel: model, queue: queue, directory: directory,
            effectsStore: effects, isSessionConnected: connected)
            .defaultAppStorage(defaults)
            .overlay(alignment: tracesHold ? .bottom : .top) {
                HStack {
                    if tracesHold {
                        Button("Clear") { ButtonInteractionTrace.reset() }
                            .frame(width: 44, height: 44).accessibilityIdentifier("clear-trace")
                        Button("Read") { trace = ButtonInteractionTrace.snapshot() }
                            .frame(width: 44, height: 44).accessibilityIdentifier("read-trace")
                        Text("Trace").accessibilityValue(trace).accessibilityIdentifier("interaction-trace")
                    }
                    Button(connected ? "Disconnect" : "Reconnect") { connected.toggle() }
                        .accessibilityIdentifier("admission-connection")
                    Text("count=\(observer.snapshot.items.count);waiting=\(observer.snapshot.items.filter { $0.status == .waiting }.count);done=\(observer.snapshot.items.filter { $0.status == .completed }.count)")
                        .accessibilityIdentifier("admission-state")
                }
                .buttonStyle(.plain)
                .font(.system(size: 10)).padding(tracesHold ? .bottom : .top, tracesHold ? 110 : 48)
            }
            .background { if tracesHold { ButtonInteractionTouchTrace() } }
            .onAppear { if tracesHold { ButtonInteractionTrace.enabled = true; ButtonInteractionTrace.reset() } }
            .onDisappear { if tracesHold { ButtonInteractionTrace.enabled = false } }
    }
}
#endif
