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
    var body: some View {
        ZStack {
            VStack {
                ForEach(Array(files.enumerated()), id: \.offset) { index, file in
                    Button("Open \(index)") { selected = file; open = true }
                        .accessibilityIdentifier("open-preview-\(index)")
                }
            }
            if open {
                PhotoPreviewView(session: session, queueModel: queue, files: files,
                                 isSessionConnected: !offline,
                                 selectedFile: $selected, collapseBursts: false,
                                 onEnqueue: { _ in
                                     if offline { hint.show(AppLocalized.resource("camera_not_connected")) }
                                     return false
                                 },
                                 onDismiss: { _ in open = false })
            }
            PhotoListHint(state: hint)
        }
        .onDisappear { hint.stop() }
    }
}
#endif
