import SwiftUI

/// Reuses the normal photo viewer while disabling transfer/crop in monitor review.
/// Android RemotePhotoReview owns a full-screen input barrier even while loading.
struct RemotePhotoReviewView: View {
    @ObservedObject var model: RemotePhotoReviewModel
    let session: CameraSession
    let queue: TransferQueueViewModel
    let connected: Bool
    @State private var selected: CameraFile?
    @State private var previewProjection = PhotoPreviewProjectionCache()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea().contentShape(Rectangle()).onTapGesture { }
            if !model.photos.isEmpty {
                PhotoPreviewView(session: session, queueModel: queue,
                    files: model.displaySnapshot.files, projection: previewProjection, review: model,
                    isSessionConnected: connected, selectedFile: $selected,
                    collapseBursts: false, onDismiss: { _ in Task { await model.close() } })
            } else {
                if model.loading { ProgressView().tint(.white) }
                else if model.failed {
                    Button(AppLocalized.resource("remote_review_retry")) { model.retry() }
                        .foregroundStyle(.white)
                } else { Text(AppLocalized.resource("remote_review_empty")).foregroundStyle(.white) }
                Button { Task { await model.close() } } label: {
                    Image(systemName: "xmark").font(.system(size: 22))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.trailing, 12).padding(.top, 8)
            }

        }
        .onAppear { selected = model.photos.first?.file }
    }
}
