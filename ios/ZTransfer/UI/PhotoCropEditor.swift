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
/// transports that ignore it, including after closing and reopening a sheet.
@MainActor
final class PhotoCropPreparation: ObservableObject {
    @Published private(set) var prepared: PreparedPhotoCrop?
    @Published private(set) var failure: CropPreparationError?
    @Published private(set) var confirming = false
    private var generation = UUID()

    func reset() {
        generation = UUID()
        prepared = nil
        failure = nil
        confirming = false
    }

    func confirm(selection: JpegCropSelection,
                 submit: @MainActor (JpegCropSelection) async -> Bool) async -> Bool {
        guard !Task.isCancelled, !confirming, selection.hasCrop, let prepared else { return false }
        let token = generation
        confirming = true
        let accepted = await submit(prepared.preview.canonicalSelection(selection))
        guard token == generation else { return false }
        // Accepted remains latched until close/reset, preventing a second
        // submission between callback completion and sheet dismissal.
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
            prepared = value
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

struct PhotoCropEditor: View {
    let image: UIImage
    let orientation: Int
    @Binding var selection: JpegCropSelection
    @State private var geometry: CropEditorGeometry
    private let initialBounds: CropBounds?

    init(image: UIImage, orientation: Int, selection: Binding<JpegCropSelection>, initialBounds: CropBounds? = nil) {
        self.image = image
        self.orientation = orientation
        self.initialBounds = initialBounds
        _selection = selection
        _geometry = State(initialValue: CropEditorGeometry(source: JpegCropSource(
            width: max(image.cgImage?.width ?? 1, 1), height: max(image.cgImage?.height ?? 1, 1),
            mcuWidth: 1, mcuHeight: 1, orientation: 1)))
    }

    private let ratios = [[(3,2),(4,3),(5,4),(16,9),(2,1)],
                          [(2,3),(3,4),(4,5),(9,16),(1,2)]]

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    Color.black
                    Image(uiImage: image).resizable()
                        .frame(width: geometry.image.width, height: geometry.image.height)
                        .position(x: geometry.image.midX, y: geometry.image.midY)
                    Path { $0.addRect(geometry.frame) }.stroke(.white, lineWidth: 2)
                    CropTouchInput(cornerAt: { geometry.corner(at: $0) }) { corner, centroid, pan, zoom in
                        update { value in
                            if let corner { try value.dragCorner(corner, pan: pan, minimum: 48) }
                            else { try value.transform(centroid: centroid, pan: pan, zoom: zoom) }
                        }
                    }
                }
                .clipped()
                .onAppear { resize(proxy.size) }
                .onChange(of: proxy.size) { resize($0) }
            }
            VStack(spacing: 6) {
                ForEach(Array(ratios.enumerated()), id: \.offset) { _, row in
                    HStack {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, pair in
                            Button("\(pair.0):\(pair.1)") { selectRatio(.fixed(pair.0, pair.1)) }
                        }
                    }
                }
                HStack {
                    Button(AppLocalized.resource("crop_free")) { selectRatio(.free) }
                    Button(AppLocalized.resource("crop_original")) { selectRatio(.original) }
                    Button("1:1") { selectRatio(.fixed(1, 1)) }
                }

            }
            .font(.caption).buttonStyle(.bordered)
            .padding(.horizontal, 8).padding(.bottom, 8)
        }
        .background(.black)
    }

    private func resize(_ size: CGSize) {
        update { value in
            if value.size == .zero, let initialBounds { try value.initialize(size, visibleBounds: initialBounds) }
            else { try value.resize(size) }
        }
    }

    private func selectRatio(_ ratio: CropEditorGeometry.Ratio) {
        ZTransferHaptics.shared.tick()
        update { $0.select(ratio) }
    }

    /// Retain the last valid editor state when a tiny image cannot represent
    /// even one unit of the requested ratio; never publish invalid geometry.
    private func update(_ operation: (inout CropEditorGeometry) throws -> Void) {
        var candidate = geometry
        do {
            try operation(&candidate)
            _ = try candidate.recipe()
            geometry = candidate
            selection = candidate.selection(orientation: orientation)
        } catch { return }
    }
}

/// A single touch stream matches Android's corner-or-transform ownership.
/// Adding a second finger permanently releases the corner for this gesture.
private struct CropTouchInput: UIViewRepresentable {
    let cornerAt: (CGPoint) -> Int?
    let onChange: (Int?, CGPoint, CGSize, CGFloat) -> Void
    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) {
        view.cornerAt = cornerAt
        view.onChange = onChange
    }
    static func dismantleUIView(_ view: Surface, coordinator: ()) { view.recognizer.isEnabled = false }

    final class Surface: UIView {
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
            if input.points.isEmpty { state = state == .possible ? .failed : .ended }
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            input.reset()
            state = state == .possible ? .failed : .cancelled
        }
        override func reset() {
            super.reset()
            input.reset()
        }
    }
}
