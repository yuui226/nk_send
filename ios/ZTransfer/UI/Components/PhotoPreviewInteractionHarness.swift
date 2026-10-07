#if DEBUG
import SwiftUI

/// Runs the production overlay against the existing in-process camera fixture.
struct PhotoPreviewInteractionHarness: View {
    private let session = CameraSession(repository: CameraRepository(debugData: .shared))
    private let files = Array(DebugCameraData.shared.files.filter { $0.fileExtension.lowercased() == ".jpg" }.prefix(3))
    @StateObject private var queue = TransferQueueViewModel(queue: TransferQueue())
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
                                 selectedFile: $selected, collapseBursts: false,
                                 onDismiss: { _ in open = false })
            }
        }
    }
}
#endif
