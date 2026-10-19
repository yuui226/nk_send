#if DEBUG
import SwiftUI

/// Runs the production overlay against the existing in-process camera fixture.
struct PhotoPreviewInteractionHarness: View {
    private let session = CameraSession(repository: CameraRepository(debugData: .shared))
    private let files = Array(DebugCameraData.shared.files.filter { $0.fileExtension.lowercased() == ".jpg" }.prefix(3))
    @StateObject private var queue = TransferQueueViewModel(queue: TransferQueue())
    @StateObject private var hint = PhotoListHintState()
    private let offline = ProcessInfo.processInfo.arguments.contains("--preview-offline-admission")
    @State private var selected: CameraFile?
    @State private var open = false
    @State private var previewProjection = PhotoPreviewProjectionCache()
    @StateObject private var effects: PhotoEffectsStore
    @StateObject private var directory: DirectoryAccessStore
    private let testingEffects = ProcessInfo.processInfo.arguments.contains("--preview-effects-gesture-test")

    init() {
        let suite = "PreviewEffectsGestureTest"
        let defaults = UserDefaults(suiteName: suite)!
        if ProcessInfo.processInfo.arguments.contains("--preview-effects-gesture-test") {
            defaults.removePersistentDomain(forName: suite)
        }
        let store = PhotoEffectsStore(defaults: defaults)
        var settings = store.settings
        settings.selectFilter(PhotoFilterCatalog.presets.first!.id)
        store.update(settings)
        _effects = StateObject(wrappedValue: store)
        _directory = StateObject(wrappedValue: DirectoryAccessStore(defaults: defaults))
    }
    var body: some View {
        ZStack {
            VStack {
                ForEach(Array(files.enumerated()), id: \.offset) { index, file in
                    Button("Open \(index)") { selected = file; open = true }
                        .accessibilityIdentifier("open-preview-\(index)")
                }
            }
            if open {
                PhotoPreviewView(session: session, queueModel: queue, files: files, projection: previewProjection,
                                 effectsStore: testingEffects ? effects : nil,
                                 effectsDirectory: testingEffects ? directory : nil,
                                 isSessionConnected: !offline,
                                 selectedFile: $selected, collapseBursts: false,
                                 onEnqueue: { _ in
                                     if offline { hint.show(AppLocalized.resource("camera_not_connected")) }
                                     return false
                                 },
                                 onDismiss: { _ in open = false })
            }
            PhotoListHint(state: hint)
            if testingEffects {
                Button("Queue") {}.accessibilityIdentifier("preview-test-queue")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.trailing, 12).zIndex(3)
            }
        }
        .previewPhotoEffectsPresentation()
        .onDisappear { hint.stop() }
    }
}
#endif
