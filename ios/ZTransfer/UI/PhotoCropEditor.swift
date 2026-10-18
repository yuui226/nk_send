import SwiftUI
import UIKit
import AVFoundation

/// The editor owns only a small FHD derivative. Original geometry remains a
/// generation concern (Android prepareCropPreview / canonical preview placement).
struct PreparedPhotoCrop: Sendable {
    let preview: CropPreview
    let image: UIImage
}

/// SwiftUI owns cancellation; this owner also rejects late completions from
/// transports that ignore it, including after closing and reopening the crop overlay.
@MainActor
final class PhotoCropPreparation: ObservableObject {
    @Published private(set) var prepared: PreparedPhotoCrop?
    @Published private(set) var failure: CropPreparationError?
    @Published private(set) var confirming = false
    private var generation = UUID()

    func reset() {
        generation = UUID()
        if prepared != nil { prepared = nil }
        if failure != nil { failure = nil }
        if confirming { confirming = false }
    }

    func confirm(selection: JpegCropSelection,
                 submit: @MainActor (JpegCropSelection) async -> Bool) async -> Bool {
        guard !Task.isCancelled, !confirming, selection.hasCrop, let prepared else { return false }
        let token = generation
        confirming = true
        let accepted = await submit(prepared.preview.canonicalSelection(selection))
        guard token == generation else { return false }
        // Accepted remains latched until close/reset, preventing a second
        // submission between callback completion and overlay dismissal.
        if !accepted { confirming = false }
        return accepted
    }

    @discardableResult
    func load(_ operation: @MainActor () async throws -> PreparedPhotoCrop?) async -> PreparedPhotoCrop? {
        reset()
        let token = generation
        do {
            try Task.checkCancellation()
            let value = try await operation()
            try Task.checkCancellation()
            guard generation == token else { return nil }
            if let value { prepared = value }
            return value
        } catch is CancellationError {
            return nil
        } catch {
            guard generation == token, !Task.isCancelled else { return nil }
            failure = error as? CropPreparationError ?? .unavailable()
            return nil
        }
    }
}

func preparePhotoCrop(image: UIImage, orientation: Int, embeddedOrientation: Int?,
                      rotation: Double) throws -> PreparedPhotoCrop {
    try Task.checkCancellation()
    guard let source = image.cgImage,
          source.width > 0, source.height > 0,
          max(source.width, source.height) <= 1920,
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: source.width, height: source.height,
            bitsPerComponent: 8, bytesPerRow: source.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
          let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else {
        throw CropPreparationError.previewRead(detail: "Invalid FHD pixels")
    }
    context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
    let preview = try prepareCropPreview(width: source.width, height: source.height,
        orientation: orientation, embeddedOrientation: embeddedOrientation, rotation: rotation) { x, y in
            let offset = y * context.bytesPerRow + x * 4
            return CGColor(colorSpace: space, components: [CGFloat(bytes[offset]) / 255,
                CGFloat(bytes[offset + 1]) / 255, CGFloat(bytes[offset + 2]) / 255, 1])!
        }.canonicalized()
    try Task.checkCancellation()
    let content = preview.content
    guard let cropped = source.cropping(to: CGRect(x: content.left, y: content.top,
        width: content.width, height: content.height)) else {
        throw CropPreparationError.previewRead(detail: "Invalid preview content")
    }
    let imageOrientation: UIImage.Orientation
    switch preview.canonicalOrientation {
    case 3: imageOrientation = .down
    case 6: imageOrientation = .right
    case 8: imageOrientation = .left
    default: imageOrientation = .up
    }
    let oriented = UIImage(cgImage: cropped, scale: 1, orientation: imageOrientation)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let size = CGSize(width: preview.source.width, height: preview.source.height)
    let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
        oriented.draw(in: CGRect(origin: .zero, size: size))
    }
    try Task.checkCancellation()
    return PreparedPhotoCrop(preview: preview, image: rendered)
}

/// High-frequency crop geometry is observed by the overlay and image transform
/// only. The owning preview reads the final selection when confirming.
@MainActor
final class PhotoCropEditingState: ObservableObject {
    @Published private(set) var geometry: CropEditorGeometry?
    private(set) var initialImage: CGRect = .zero
    private(set) var selection: JpegCropSelection?
    let controls = PhotoCropControlState()

    func begin(preview: CropPreview, placement: CropImagePlacement) throws {
        var value = CropEditorGeometry(source: preview.source)
        let content = placement.contentRect(preview: preview)
        try value.initialize(placement.viewport, placement: content)
        initialImage = content
        publish(value)
    }

    func reset() {
        initialImage = .zero
        publish(nil)
    }

    private func publish(_ value: CropEditorGeometry?) {
        guard geometry != value else { return }
        selection = value?.selection(orientation: 1)
        geometry = value
        controls.update(ratio: value?.ratio, hasCrop: selection?.hasCrop == true)
    }
    func update(_ operation: (inout CropEditorGeometry) throws -> Void) {
        guard var value = geometry else { return }
        do {
            try operation(&value)
            guard value != geometry else { return }
            _ = try value.recipe()
            publish(value)
        } catch { return }
    }
}

/// Ratio/readiness and confirmation admission change far less frequently
/// than the frame/image geometry. No gesture or export state lives here.
@MainActor
final class PhotoCropControlState: ObservableObject {
    struct Snapshot: Equatable {
        var ratio: CropEditorGeometry.Ratio?
        var hasCrop = false
    }
    @Published private(set) var snapshot = Snapshot()
    func update(ratio: CropEditorGeometry.Ratio?, hasCrop: Bool) {
        let next = Snapshot(ratio: ratio, hasCrop: hasCrop)
        if next != snapshot { snapshot = next }
    }
}

/// Reuses the existing preview texture. Ratio changes leave this transform
/// unchanged; pan/pinch changes only this small observer, not the pager body.
struct PhotoCropImageTransform: ViewModifier {
    @ObservedObject var editor: PhotoCropEditingState
    let active: Bool
    func body(content: Content) -> some View {
        let initial = editor.initialImage
        let image = editor.geometry?.image ?? initial
        let scale = active && initial.width > 0 ? image.width / initial.width : 1
        let offset = active && initial.width > 0
            ? CGSize(width: image.minX - initial.minX * scale, height: image.minY - initial.minY * scale) : .zero
        content.scaleEffect(scale, anchor: .topLeading).offset(offset)
            .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.22), value: active)
    }
}

/// Android CropEditor.kt: transparent controls over the same FHD image.
struct PhotoCropEditor: View {
    let editor: PhotoCropEditingState
    @ObservedObject private var controls: PhotoCropControlState
    let confirming: Bool
    let loading: Bool
    let failure: CropPreparationError?
    let bottomClearance: CGFloat
    let onRetry: () -> Void
    let onCancel: () -> Void
    #if DEBUG
    var didRender: (() -> Void)? = nil
    #endif
    private let ratios = [[(3,2),(4,3),(5,4),(16,9),(2,1)],
                          [(2,3),(3,4),(4,5),(9,16),(1,2)]]

    init(editor: PhotoCropEditingState, confirming: Bool, loading: Bool,
         failure: CropPreparationError?, bottomClearance: CGFloat,
         onRetry: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.editor = editor
        controls = editor.controls
        self.confirming = confirming
        self.loading = loading
        self.failure = failure
        self.bottomClearance = bottomClearance
        self.onRetry = onRetry
        self.onCancel = onCancel
    }

    var body: some View {
        #if DEBUG
        let _ = didRender?()
        #endif
        ZStack {
            if controls.snapshot.ratio != nil {
                PhotoCropGestureSurface(editor: editor, confirming: confirming)
            } else {
                VStack(spacing: 12) {
                    if loading && failure == nil { ProgressView().tint(ZTransferColors.accentBlue).frame(width: 24, height: 24) }
                    if let failure {
                        Text(AppLocalized.resource(failure.messageKey)).font(.system(size: 12)).foregroundStyle(.white)
                        Button { onRetry() } label: {
                            Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                        }.foregroundStyle(ZTransferColors.accentBlue)
                    }
                }
            }
            VStack(spacing: 2) {
                ForEach(Array(ratios.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 8) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, pair in
                            option("\(pair.0):\(pair.1)", ratio: .fixed(pair.0, pair.1))
                        }
                    }
                }
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        option(AppLocalized.resource("crop_free"), ratio: .free)
                        option(AppLocalized.resource("crop_original"), ratio: .original)
                        option("1:1", ratio: .fixed(1, 1))
                    }
                    PreviewCircleButton(icon: .close, accessibilityKey: "crop_cancel", tint: .red, action: onCancel)
                        .disabled(confirming)
                    Color.clear.frame(width: 44, height: 44).allowsHitTesting(false)
                }.frame(height: 44)
            }
            .padding(.horizontal, 20).padding(.bottom, bottomClearance)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private func option(_ title: String, ratio: CropEditorGeometry.Ratio) -> some View {
        let selected = controls.snapshot.ratio == ratio
        let enabled = controls.snapshot.ratio != nil && !confirming
        return Button {
            ZTransferHaptics.shared.tick()
            editor.update { $0.select(ratio) }
        } label: {
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                .foregroundStyle((selected ? ZTransferColors.accentBlue : .white.opacity(0.85)).opacity(enabled ? 1 : 0.35))
                .frame(maxWidth: .infinity).frame(height: 36)
                .background {
                    RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.16, green: 0.17, blue: 0.19).opacity(selected ? 0.42 : 0.46))
                    if selected { RoundedRectangle(cornerRadius: 10).fill(ZTransferColors.accentBlue.opacity(0.24)) }
                }
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(
                    (selected ? ZTransferColors.accentBlue.opacity(0.85) : .white.opacity(0.22)).opacity(enabled ? 1 : 0.1), lineWidth: 1))
                .padding(.vertical, 2).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled)
        .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.16), value: selected)
    }
}

/// Geometry and the 120 ms touching grid update this leaf only. The recognizer
/// still queries the latest geometry and keeps one corner-or-transform stream.
private struct PhotoCropGestureSurface: View {
    @ObservedObject var editor: PhotoCropEditingState
    let confirming: Bool
    @State private var touching = false
    var body: some View {
        if let geometry = editor.geometry {
            CropFrameDrawing(image: geometry.image, frame: geometry.frame, gridAlpha: touching ? 0.45 : 0)
                .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.12), value: touching)
                .allowsHitTesting(false)
            CropTouchInput(cornerAt: { editor.geometry?.corner(at: $0) },
                           onTouching: { if touching != $0 { touching = $0 } }) { corner, centroid, pan, zoom in
                editor.update { value in
                    if let corner { try value.dragCorner(corner, pan: pan, minimum: 48) }
                    else { try value.transform(centroid: centroid, pan: pan, zoom: zoom) }
                }
            }.allowsHitTesting(!confirming)
        }
    }
}

@preconcurrency
struct CropFrameDrawing: View, Animatable {
    let image: CGRect
    let frame: CGRect
    var gridAlpha: CGFloat
    nonisolated var animatableData: CGFloat {
        get { gridAlpha }
        set { gridAlpha = newValue }
    }
    var body: some View {
        Canvas { context, size in
            var shade = Path()
            shade.addRect(image.intersection(CGRect(origin: .zero, size: size)))
            shade.addRect(frame)
            context.fill(shade, with: .color(.black.opacity(0.58)), style: FillStyle(eoFill: true))
            context.stroke(Path(frame), with: .color(.white.opacity(0.85)), lineWidth: 1)
            if gridAlpha > 0 {
                var grid = Path()
                for i in 1...2 {
                    let x = frame.minX + frame.width * CGFloat(i) / 3
                    let y = frame.minY + frame.height * CGFloat(i) / 3
                    grid.move(to: CGPoint(x: x, y: frame.minY)); grid.addLine(to: CGPoint(x: x, y: frame.maxY))
                    grid.move(to: CGPoint(x: frame.minX, y: y)); grid.addLine(to: CGPoint(x: frame.maxX, y: y))
                }
                context.stroke(grid, with: .color(.white.opacity(gridAlpha)), lineWidth: 0.65)
            }
            var corners = Path()
            for (i, p) in [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY),
                           CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.minX, y: frame.maxY)].enumerated() {
                corners.move(to: CGPoint(x: p.x + (i == 0 || i == 3 ? 16 : -16), y: p.y))
                corners.addLine(to: p)
                corners.addLine(to: CGPoint(x: p.x, y: p.y + (i < 2 ? 16 : -16)))
            }
            context.stroke(corners, with: .color(.white), lineWidth: 3)
        }.clipped()
    }
}

/// A single touch stream matches Android's corner-or-transform ownership.
/// Adding a second finger permanently releases the corner for this gesture.
private struct CropTouchInput: UIViewRepresentable {
    let cornerAt: (CGPoint) -> Int?
    let onTouching: (Bool) -> Void
    let onChange: (Int?, CGPoint, CGSize, CGFloat) -> Void
    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) {
        view.onTouching = onTouching
        view.cornerAt = cornerAt
        view.onChange = onChange
    }
    static func dismantleUIView(_ view: Surface, coordinator: ()) { view.recognizer.isEnabled = false }

    final class Surface: UIView {
        var onTouching: ((Bool) -> Void)?
        var cornerAt: ((CGPoint) -> Int?)?
        var onChange: ((Int?, CGPoint, CGSize, CGFloat) -> Void)?
        lazy var recognizer: Input = {
            let input = Input(); input.surface = self; return input
        }()
        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            addGestureRecognizer(recognizer)
        }
        private var previousSize: CGSize = .zero
        override func layoutSubviews() {
            super.layoutSubviews()
            if previousSize != .zero, bounds.size != previousSize {
                recognizer.isEnabled = false
                recognizer.isEnabled = true
            }
            previousSize = bounds.size
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }

    final class Input: UIGestureRecognizer {
        weak var surface: Surface?
        private var input = CropTouchState<UITouch>()
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let surface else { state = .failed; return }
            surface.onTouching?(true)
            input.begin(Dictionary(uniqueKeysWithValues: touches.map { ($0, $0.location(in: surface)) })) {
                surface.cornerAt?($0)
            }
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let surface else { return }
            let positions = Dictionary(uniqueKeysWithValues: input.points.keys.map { ($0, $0.location(in: surface)) })
            guard let change = input.move(positions) else { return }
            state = state == .possible ? .began : .changed
            surface.onChange?(change.corner, change.centroid, change.pan, change.zoom)
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            input.end(touches)
            if input.points.isEmpty { surface?.onTouching?(false); state = state == .possible ? .failed : .ended }
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            input.reset()
            surface?.onTouching?(false)
            state = state == .possible ? .failed : .cancelled
        }
        override func reset() {
            super.reset()
            surface?.onTouching?(false)
            input.reset()
        }
    }
}
