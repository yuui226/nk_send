import SwiftUI

/// RemoteReviewSurface maps physical safeDrawing insets into the rotated canvas.
/// The backdrop fills the physical display; only the content avoids system bars.
struct RemoteReviewLayout {
    let physicalSize: CGSize
    let canvasSize: CGSize
    let contentInsets: EdgeInsets
    init(size: CGSize, safe: EdgeInsets, rotation: Int) {
        physicalSize = CGSize(width: size.width + safe.leading + safe.trailing,
                              height: size.height + safe.top + safe.bottom)
        canvasSize = rotation == 0 ? physicalSize : CGSize(width: physicalSize.height, height: physicalSize.width)
        switch rotation {
        case 1: contentInsets = EdgeInsets(top: safe.trailing, leading: safe.top,
                                          bottom: safe.leading, trailing: safe.bottom)
        case 2: contentInsets = EdgeInsets(top: safe.leading, leading: safe.bottom,
                                          bottom: safe.trailing, trailing: safe.top)
        default: contentInsets = safe
        }
    }
}

struct RemoteReviewSurface<Content: View>: View {
    let rotation: Int
    @ViewBuilder let content: (Bool, EdgeInsets) -> Content
    var body: some View {
        GeometryReader { proxy in
            let layout = RemoteReviewLayout(size: proxy.size, safe: proxy.safeAreaInsets, rotation: rotation)
            content(rotation != 0, layout.contentInsets)
                .frame(width: layout.canvasSize.width, height: layout.canvasSize.height)
                .rotationEffect(.degrees(rotation == 1 ? 90 : rotation == 2 ? -90 : 0))
                .frame(width: layout.physicalSize.width, height: layout.physicalSize.height)
                .offset(x: -proxy.safeAreaInsets.leading, y: -proxy.safeAreaInsets.top)
        }
    }
}

/// RemotePhotoReview.RemoteReviewButton's hand-drawn 24x28 camera-photo key.
struct RemoteReviewEntryButton: View {
    let large: Bool
    var sizeScale: CGFloat = 1
    let enabled: Bool
    let action: () -> Void
    @AppStorage("skin_preset") private var skinPreset = ZTransferButtonSkin.defaultPreset.rawValue
    private var tint: Color {
        ZTransferButtonSkin(storedValue: skinPreset) == .cameraControls
            ? Color(red: 213.0 / 255, green: 216.0 / 255, blue: 218.0 / 255)
            : ZTransferColors.primaryText.opacity(0.9)
    }
    var body: some View {
        Button(action: action) {
            RemoteReviewEntryMark().foregroundStyle(tint)
                .frame(width: (large ? 24 : 21) * sizeScale, height: (large ? 28 : 24.5) * sizeScale)
                .frame(width: (large ? 48 : 40) * sizeScale, height: (large ? 56 : 48) * sizeScale)
        }
        .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: (large ? 14 : 12) * sizeScale,
                                               materialContentColor: tint))
        .disabled(!enabled)
        .accessibilityLabel(AppLocalized.resource("remote_review"))
    }
}

struct RemoteReviewEntryMark: View {
    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 24, y: size.height / 28)
            let stroke = StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
            context.stroke(Path(roundedRect: CGRect(x: 2, y: 1, width: 20, height: 26), cornerRadius: 3.5),
                           with: .foreground, style: stroke)
            context.fill(Path(ellipseIn: CGRect(x: 14.2, y: 6.2, width: 3.6, height: 3.6)), with: .foreground)
            var mountain = Path()
            mountain.move(to: CGPoint(x: 5.5, y: 21)); mountain.addLine(to: CGPoint(x: 10.5, y: 15.5))
            mountain.addLine(to: CGPoint(x: 18.5, y: 21))
            context.stroke(mountain, with: .foreground, style: stroke)
        }
    }
}

/// Keeps the review/frame gate alive for Android Motion.overlayCollapse.
/// Repeated close requests cannot restart the fade or resume live view twice.
@MainActor
final class RemoteReviewDismissal: ObservableObject {
    @Published private(set) var closing = false
    private var task: Task<Void, Never>?
    private let close: @MainActor () async -> Void
    init(close: @escaping @MainActor () async -> Void) { self.close = close }
    func requestClose() {
        guard !closing else { return }
        closing = true
        task = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(260)) }
            catch { return }
            guard let self else { return }
            await close()
            task = nil
        }
    }
    func cancel() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}

/// Reuses the normal photo viewer while disabling transfer/crop in monitor review.
/// Android RemotePhotoReview owns a full-screen input barrier even while loading.
struct RemotePhotoReviewView: View {
    @ObservedObject var model: RemotePhotoReviewModel
    let session: CameraSession
    let queue: TransferQueueViewModel
    let connected: Bool
    var landscape = false
    var contentInsets = EdgeInsets()
    @State private var selected: CameraFile?
    @State private var previewProjection = PhotoPreviewProjectionCache()
    @StateObject private var dismissal: RemoteReviewDismissal
    @AppStorage("skin_preset") private var skinPreset = ZTransferButtonSkin.defaultPreset.rawValue

    private var closeTint: Color {
        // Native liquid glass follows the black review backdrop, even in the
        // app's light theme. Its code-drawn mark must follow that dark surface.
        ZTransferButtonSkin(storedValue: skinPreset) == .liquidGlass ? .white : ZTransferColors.primaryText
    }

    init(model: RemotePhotoReviewModel, session: CameraSession, queue: TransferQueueViewModel,
         connected: Bool, landscape: Bool = false, contentInsets: EdgeInsets = EdgeInsets(),
         dismissal: RemoteReviewDismissal? = nil) {
        self.model = model; self.session = session; self.queue = queue; self.connected = connected
        self.landscape = landscape; self.contentInsets = contentInsets
        _dismissal = StateObject(wrappedValue: dismissal ?? RemoteReviewDismissal { await model.close() })
    }

    var body: some View {
        ZStack {
            Color.black.contentShape(Rectangle()).onTapGesture { }
                .gesture(DragGesture(minimumDistance: 0).onChanged { _ in })
            ZStack {
            if !model.photos.isEmpty {
                PhotoPreviewView(session: session, queueModel: queue,
                    files: model.displaySnapshot.files, projection: previewProjection, review: model,
                    landscapeReview: landscape,
                    isSessionConnected: connected, selectedFile: $selected,
                    collapseBursts: false, onDismiss: { _ in dismissal.requestClose() })
            } else {
                if model.loading { RemoteCameraToolLoading(diameter: 28, strokeWidth: 2, color: .white) }
                else if model.failed {
                    RemoteReviewRetryButton { model.retry() }
                } else { Text(AppLocalized.resource("remote_review_empty")).zTransferTypography(.bodyLarge, weight: .regular).foregroundStyle(.white) }
            }
            // RemoteReviewCloseButton remains present for loading, empty,
            // failed and loaded photos, independently of the inner entry fade.
            Button { dismissal.requestClose() } label: {
                PreviewControlMark(icon: .close, tint: closeTint)
                    .frame(width: 22, height: 22)
                    .frame(width: 40, height: 36)
            }
            .foregroundStyle(closeTint)
            .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 22))
            .accessibilityLabel(AppLocalized.resource("cd_close"))
            .accessibilityIdentifier("remote-review-close")
            .padding(.top, 8).padding(.trailing, landscape ? 4 : 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .padding(contentInsets)
            .allowsHitTesting(!dismissal.closing)
        }
        // Fade the black surface, image and controls as one layer. The input
        // barrier and paused frame gate remain until overlayCollapse finishes.
        .opacity(dismissal.closing ? 0 : 1)
        .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.26), value: dismissal.closing)
        .onAppear { selected = model.photos.first?.file }
        .onDisappear { dismissal.cancel() }
    }
}

/// Material3 TextButton: shared by empty-catalog and per-page retry. The
/// disabled disconnected message keeps its explicitly white text on Android.
struct RemoteReviewRetryButton: View {
    var connected = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(AppLocalized.resource(connected ? "remote_review_retry" : "remote_review_disconnected"))
                .zTransferTypography(.labelLarge).foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(minWidth: 58, minHeight: 40).frame(minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!connected)
    }
}
