import SwiftUI
import UIKit

/// One short clock for all first-batch cells. The list owns the reference in
/// State; only this opacity modifier observes frames, never the list model,
/// catalog grouping, image loading or bitmap decoding.
@MainActor
final class PhotoThumbnailBatchEntrance: ObservableObject {
    @Published private(set) var opacity: Float = 0
    private var fade = PhotoThumbnailFade()
    private var link: CADisplayLink?
    private let automaticFrames: Bool
    var clockRunning: Bool { link != nil }

    init(automaticFrames: Bool = true) { self.automaticFrames = automaticFrames }
    func update(hasItems: Bool) {
        fade.update(ready: hasItems)
        guard fade.isRunning else { stop(); return }
        guard automaticFrames, link == nil else { return }
        let next = ZTransferDisplayLink.make(owner: self) { owner, frame in
            owner.advance(Int64(frame.timestamp * 1_000_000_000))
        }
        link = next; next.add(to: .main, forMode: .common)
    }
    func advance(_ nanos: Int64) {
        fade.advance(nanos)
        if opacity != fade.opacity { opacity = fade.opacity }
        if !fade.isRunning { stop() }
    }
    private func stop() { link?.invalidate(); link = nil }
}

struct PhotoThumbnailBatchOpacity: ViewModifier {
    @ObservedObject var entrance: PhotoThumbnailBatchEntrance
    func body(content: Content) -> some View { content.opacity(Double(entrance.opacity)) }
}

private struct PhotoThumbnailImageIdentity: Hashable {
    let session: ObjectIdentifier?
    let handle: UInt32?
    let fileName: String?
    let size: UInt64?
    let captureDate: String?
    init(session: CameraSession?, file: CameraFile?) {
        self.session = session.map(ObjectIdentifier.init)
        handle = file?.id; fileName = file?.fileName; size = file?.size; captureDate = file?.captureDate
    }
}

struct PhotoThumbnailImage: View {
    let session: CameraSession?
    let file: CameraFile?
    let loadEnabled: Bool
    let allowRemote: Bool
    let transfersBusy: Bool
    var cornerRadius: CGFloat = 8
    var showsPlaceholderIcon = true
    var stacked = false
    var expandedBurst = false

    var body: some View {
        PhotoThumbnailImageContent(session: session, file: file, loadEnabled: loadEnabled,
            allowRemote: allowRemote, transfersBusy: transfersBusy, cornerRadius: cornerRadius,
            showsPlaceholderIcon: showsPlaceholderIcon, stacked: stacked, expandedBurst: expandedBurst)
            .id(PhotoThumbnailImageIdentity(session: session, file: file))
    }
}

private struct PhotoThumbnailImageContent: View {
    let session: CameraSession?
    let file: CameraFile?
    let loadEnabled: Bool
    let allowRemote: Bool
    let transfersBusy: Bool
    let cornerRadius: CGFloat
    let showsPlaceholderIcon: Bool
    let stacked: Bool
    let expandedBurst: Bool
    @Environment(\.colorScheme) private var scheme
    @AppStorage("skin_preset") private var skinName = ZTransferButtonSkin.defaultPreset.rawValue
    @StateObject private var loader: PhotoThumbnailLoader<UIImage>
    private struct ReadKey: Hashable {
        let enabled: Bool
        let remote: Bool
        let busy: Bool
    }

    init(session: CameraSession?, file: CameraFile?, loadEnabled: Bool,
         allowRemote: Bool, transfersBusy: Bool, cornerRadius: CGFloat, showsPlaceholderIcon: Bool,
         stacked: Bool, expandedBurst: Bool) {
        self.session = session; self.file = file; self.loadEnabled = loadEnabled
        self.allowRemote = allowRemote; self.transfersBusy = transfersBusy
        self.cornerRadius = cornerRadius; self.showsPlaceholderIcon = showsPlaceholderIcon
        self.stacked = stacked; self.expandedBurst = expandedBurst
        _loader = StateObject(wrappedValue: PhotoThumbnailLoader(
            cached: file.flatMap { session?.memoryThumbnailImage(file: $0) }))
    }

    var body: some View {
        Group {
            if loader.cachedAtMount { imageContent }
            else {
                imageContent.task(id: ReadKey(enabled: loadEnabled, remote: allowRemote, busy: transfersBusy)) {
                    guard let session, let file else { return }
                    // Retain the approved STA ordered-fill contract: cells
                    // observe cache readiness, never start a parallel STA read.
                    await loader.load(enabled: loadEnabled,
                        allowRemote: allowRemote && session.wirelessMode != .sta,
                        updates: { await session.thumbnailUpdates(handle: file.id) },
                        read: { try await session.thumbnailImage(file: file, allowRemote: $0) })
                }
            }
        }
        .onDisappear { loader.finishFade() }
    }

    private var imageContent: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius).fill(Color.black.opacity(0.08))
            if showsPlaceholderIcon, !loader.fadeComplete {
                Image(systemName: file.map {
                    [".mov", ".mp4"].contains($0.fileExtension) ? "film" : "photo"
                } ?? "photo")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(Color.secondary.opacity(0.4))
            }
            if let image = loader.image {
                PhotoThumbnailBitmap(image: image, cornerRadius: cornerRadius,
                    fade: !loader.fadeComplete, onFadeComplete: { loader.finishFade() })
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(expandedBurst ? ZTransferColors.accentOrange.opacity(0.92) : borderColor,
                              lineWidth: expandedBurst ? 1 : 0.75)
                .allowsHitTesting(false)
        }
    }

    private var borderColor: Color {
        // FileListScreen thumbnailThemeBorderColor/stackedThumbnailThemeBorderColor.
        // The approved iOS liquid-glass variant shares glass's neutral outline.
        let dark = scheme == .dark
        let hex: UInt32
        let alpha: Double
        switch ZTransferButtonSkin(storedValue: skinName) {
        case .frostedGlass, .liquidGlass: hex = dark ? 0xffffff : 0; alpha = dark ? 0.12 : 0.09
        case .titanium: hex = dark ? 0xd7e2e7 : 0x46545b; alpha = dark ? 0.20 : 0.17
        case .wood: hex = dark ? 0xe4b979 : 0x623519; alpha = dark ? 0.20 : 0.17
        case .cameraControls: hex = dark ? 0xcdd3d6 : 0x23272a; alpha = dark ? 0.16 : 0.18
        }
        return Color(.sRGB, red: Double((hex >> 16) & 255) / 255,
            green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255,
            opacity: stacked ? min(0.36, alpha * 1.55) : alpha)
    }
}

/// Reuses CameraSession's decoded UIImage. Rounded cropping and rotated edge
/// antialiasing happen on the image layer; no copied bitmap or drawingGroup.
struct PhotoThumbnailBitmap: UIViewRepresentable {
    let image: UIImage
    let cornerRadius: CGFloat
    let fade: Bool
    var onFadeComplete: () -> Void = {}

    func makeUIView(context: Context) -> PhotoThumbnailBitmapView { PhotoThumbnailBitmapView() }
    func updateUIView(_ view: PhotoThumbnailBitmapView, context: Context) {
        view.configure(image: image, cornerRadius: cornerRadius, fade: fade, onFadeComplete: onFadeComplete)
    }
    static func dismantleUIView(_ view: PhotoThumbnailBitmapView, coordinator: ()) { view.stop() }
}

@MainActor
final class PhotoThumbnailBitmapView: UIImageView {
    private var fade = PhotoThumbnailFade(initiallyVisible: true)
    private var link: CADisplayLink?
    private var complete: (() -> Void)?
    private var radius: CGFloat = 8
    private let automaticFrames: Bool
    var clockRunning: Bool { link != nil }
    var imageOpacity: Float { layer.opacity }

    init(automaticFrames: Bool = true) {
        self.automaticFrames = automaticFrames
        super.init(frame: .zero)
        contentMode = .scaleAspectFill
        isUserInteractionEnabled = false
        clipsToBounds = true
        layer.cornerCurve = .circular
        layer.allowsEdgeAntialiasing = true
        layer.edgeAntialiasingMask = [.layerLeftEdge, .layerRightEdge, .layerTopEdge, .layerBottomEdge]
        layer.shouldRasterize = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: CGSize { .init(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric) }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.cornerRadius = max(0, min(radius, min(bounds.width, bounds.height) / 2))
        CATransaction.commit()
    }

    func configure(image: UIImage, cornerRadius: CGFloat, fade shouldFade: Bool, onFadeComplete: @escaping () -> Void) {
        // SwiftUI can update badges/progress without changing the bitmap.
        // Do not schedule another UIKit layout for the same corner geometry.
        if radius != cornerRadius { radius = cornerRadius; setNeedsLayout() }
        guard self.image !== image else {
            // An already-ready cell leaving/re-entering is a cache hit. The
            // same decoded image must not keep an interrupted partial alpha.
            if !shouldFade { stop(); fade = .init(initiallyVisible: true); setOpacity(1) }
            return
        }
        stop()
        self.image = image
        complete = shouldFade ? onFadeComplete : nil
        fade = PhotoThumbnailFade(initiallyVisible: !shouldFade)
        fade.update(ready: true)
        setOpacity(fade.opacity)
        guard fade.isRunning, automaticFrames else { return }
        let next = ZTransferDisplayLink.make(owner: self) { owner, frame in
            owner.advance(Int64(frame.timestamp * 1_000_000_000))
        }
        link = next; next.add(to: .main, forMode: .common)
    }
    func advance(_ nanos: Int64) {
        guard fade.isRunning else { return }
        fade.advance(nanos)
        setOpacity(fade.opacity)
        if !fade.isRunning {
            let callback = complete
            stop(); callback?()
        }
    }
    private func setOpacity(_ value: Float) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.opacity = value
        CATransaction.commit()
    }
    func stop() { link?.invalidate(); link = nil; complete = nil }
}
