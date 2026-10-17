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

    init() {
        let suite = "PhotoListAdmissionUITest"
        let preferences = UserDefaults(suiteName: suite)!
        preferences.removePersistentDomain(forName: suite)
        preferences.set(ProcessInfo.processInfo.arguments.contains("--defer-admission"), forKey: "defer_transfer_start")
        preferences.set(ProcessInfo.processInfo.arguments.contains("--preview-admission"), forKey: "tap_to_preview")
        let burst = ProcessInfo.processInfo.arguments.contains("--burst-admission")
        preferences.set(burst, forKey: "collapse_burst_photos")
        preferences.set(TransferStorageMode.unified.rawValue, forKey: TransferStorageMode.persistenceKey)
        defaults = preferences
        let files = (701...(burst ? 703 : 702)).map { id in
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
            .overlay(alignment: .top) {
                HStack {
                    Button(connected ? "Disconnect" : "Reconnect") { connected.toggle() }
                        .accessibilityIdentifier("admission-connection")
                    Text("count=\(observer.snapshot.items.count);waiting=\(observer.snapshot.items.filter { $0.status == .waiting }.count);done=\(observer.snapshot.items.filter { $0.status == .completed }.count)")
                        .accessibilityIdentifier("admission-state")
                }
                .font(.system(size: 10)).padding(.top, 48)
            }
    }
}
#endif
