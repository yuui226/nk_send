import SwiftUI
import UIKit
import QuartzCore

/// Native monitor surface. Transport and frame lifecycle live in
/// `RemoteViewModel`; this view only renders the camera frame and the controls
/// that are already present in Android's RemoteScreen.
struct RemoteView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: RemoteViewModel
    @State private var zoom: CGFloat = 1
    @State private var selectedField: RemoteExposureField?
    // Desqueeze is an Android preference.  The histogram and level overlays
    // are RemoteScreen session controls and deliberately reset on entry.
    @AppStorage("remote_desqueeze_multiplier") private var desqueeze = 1.0
    @AppStorage("remote_audio_levels_visible") private var audioLevelsVisible = true
    @State private var histogramVisible = false
    // Android RemoteScreen defaults the FPS overlay to visible for every session.
    @State private var showFps = true
    @State private var levelVisible = false
    @State private var framingGrid: IOSViewfinderGrid = .off
    @State private var zebraVisible = false
    @State private var zebraMask: IOSZebraMask?
    @State private var lastZebraUpdate = 0.0

    init(session: CameraSession) {
        _model = StateObject(wrappedValue: RemoteViewModel(camera: session))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { proxy in
                if let image = model.frameImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(zoom)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in zoom = min(max(value, 1), 4) }
                                .onEnded { _ in withAnimation(ZTransferMotion.standard) { zoom = min(max(zoom, 1), 4) } }
                        )
                        .simultaneousGesture(
                            SpatialTapGesture().onEnded { value in
                                let aspect = (image.size.width / max(image.size.height, 1)) * CGFloat(desqueeze)
                                let rect = fitImageRect(in: proxy.size, aspect: aspect)
                                guard rect.contains(value.location) else { return }
                                let x = Double((value.location.x - rect.minX) / rect.width)
                                let y = Double((value.location.y - rect.minY) / rect.height)
                                model.focus(at: RemoteFocusPoint(x: x, y: y),
                                            coordinateSize: image.size)
                            }
                        )
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .aspectRatio((image.size.width / max(image.size.height, 1)) * CGFloat(desqueeze), contentMode: .fit)
                    if let point = model.state.focus.point,
                       model.state.focus.phase != .idle {
                        RemoteFocusReticle(phase: model.state.focus.phase,
                                           point: point,
                                           nonce: model.state.focus.nonce,
                                           aspect: (image.size.width / max(image.size.height, 1)) * CGFloat(desqueeze))
                    }
                    if histogramVisible {
                        RemoteHistogramOverlay(image: image)
                            .frame(width: 150, height: 72)
                            .padding(12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                    if levelVisible, let roll = model.levelRoll {
                        Rectangle()
                            .fill(.yellow.opacity(0.8))
                            .frame(width: 120, height: 2)
                            .rotationEffect(.degrees(roll))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)
                    }
                    if framingGrid != .off {
                        IOSFramingGridOverlay(divisions: framingGrid.divisions,
                                              aspect: (image.size.width / max(image.size.height, 1)) * CGFloat(desqueeze))
                            .allowsHitTesting(false)
                    }
                    if model.movieMode, audioLevelsVisible,
                       let levels = model.frameMetadata?.soundLevels {
                        IOSSoundMeter(levels: levels)
                            .frame(width: 32, height: 116)
                            .padding(.leading, 10)
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: .bottomLeading)
                            .allowsHitTesting(false)
                    }
                    if let metadata = model.frameMetadata,
                       let focusFrame = metadata.selectedFocusFrame,
                       metadata.focusJudgement != .none {
                        IOSFocusFrameOverlay(frame: focusFrame,
                                             aspect: (image.size.width / max(image.size.height, 1)) * CGFloat(desqueeze))
                            .allowsHitTesting(false)
                    }
                    if zebraVisible, let zebraMask {
                        IOSZebraOverlay(mask: zebraMask,
                                        aspect: (image.size.width / max(image.size.height, 1)) * CGFloat(desqueeze))
                            .allowsHitTesting(false)
                    }
                    if showFps, model.state.fps > 0 {
                        Text(String(format: "%.1f fps", model.state.fps))
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: .bottomTrailing)
                            .padding(.trailing, 8)
                            .padding(.bottom, 8)
                            .allowsHitTesting(false)
                    }
                    if model.state.liveViewStable {
                        HStack(spacing: 4) {
                            RemoteStatusBadge(
                                text: RemoteExposureParameters.format(
                                    .liveViewSelector,
                                    raw: model.movieMode ? 1 : 0,
                                ),
                                weight: .bold,
                            )
                            if let focusMode = model.focusModeDescriptor {
                                RemoteStatusBadge(
                                    text: RemoteExposureParameters.format(
                                        .focusMode,
                                        raw: focusMode.current,
                                    ),
                                    weight: .semibold,
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .topLeading)
                        .padding(8)
                        .allowsHitTesting(false)
                    }
                } else {
                    ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .clipped()

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 38, height: 36)
                            .background(.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if sessionFailed {
                        Button { model.start() } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 38, height: 36)
                                .background(.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 18))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                HStack(spacing: 8) {
                    Button {
                        withAnimation(ZTransferMotion.standard) { showFps.toggle() }
                    } label: {
                        Text("FPS")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    Button {
                        withAnimation(ZTransferMotion.standard) { histogramVisible.toggle() }
                    } label: {
                        Image(systemName: "chart.bar.xaxis")
                    }
                    Button {
                        withAnimation(ZTransferMotion.standard) {
                            desqueeze = RemoteDisplayOptions.nextDesqueeze(after: desqueeze)
                        }
                    } label: {
                        if desqueeze > 1.001 {
                            Text(RemoteDisplayOptions.label(for: desqueeze))
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                        } else {
                            Image(systemName: "aspectratio")
                        }
                    }
                    Button {
                        withAnimation(ZTransferMotion.standard) { levelVisible.toggle() }
                    } label: {
                        Image(systemName: "level")
                    }
                    Button {
                        withAnimation(ZTransferMotion.standard) { framingGrid = framingGrid.next }
                    } label: {
                        Image(systemName: "square.grid.3x3")
                    }
                    if model.movieMode {
                        Button {
                            withAnimation(ZTransferMotion.standard) { audioLevelsVisible.toggle() }
                        } label: {
                            Image(systemName: audioLevelsVisible ? "waveform" : "waveform.slash")
                        }
                    }
                    Button {
                        withAnimation(ZTransferMotion.standard) {
                            zebraVisible.toggle()
                            updateZebraMask(force: true)
                        }
                    } label: {
                        Image(systemName: zebraVisible ? "rectangle.dashed.badge.record" : "rectangle.dashed")
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .trailing)
                if model.state.capture == .recording {
                    HStack(spacing: 5) {
                        Circle().fill(.red).frame(width: 7, height: 7)
                        Text(String(format: "%d:%02d", model.recordingSeconds / 60,
                                    model.recordingSeconds % 60))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 14)
                }
                Spacer()
                exposureGrid
                HStack(spacing: 18) {
                    Button {
                        withAnimation(ZTransferMotion.standard) { zoom = zoom > 1.01 ? 1 : 2.5 }
                    } label: {
                        Image(systemName: zoom > 1.01 ? "minus.magnifyingglass" : "plus.magnifyingglass")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 42, height: 42)
                    }
                    .buttonStyle(.plain)
                    Button { model.movieMode ? model.toggleRecording() : model.capture() } label: {
                        ZStack {
                            Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                            RoundedRectangle(cornerRadius: model.state.capture == .recording ? 7 : 30)
                                .fill(model.movieMode ? .red : .white)
                                .frame(width: model.state.capture == .recording ? 28 : 60,
                                       height: model.state.capture == .recording ? 28 : 60)
                                .animation(ZTransferMotion.emphasized, value: model.state.capture)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(model.state.session != .ready || model.recordingBusy ||
                              (!model.movieMode && model.state.capture != .idle) ||
                              (model.movieMode && (model.state.capture == .focusing || model.state.capture == .stopping)))
                    Button { dismiss() } label: {
                        Image(systemName: "arrow.down.to.line.compact")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 42, height: 42)
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(.white)
                .padding(.bottom, 18)
            }
        }
        .overlay(alignment: .bottom) {
            if let hint = model.recordingHint {
                Text(hint)
                    .font(.system(size: 14, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(ZTransferColors.primaryText)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .padding(.horizontal, 20).padding(.bottom, 28)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(ZTransferMotion.standard, value: model.recordingHint)
        .statusBarHidden(true)
        .task { model.start() }
        .task { model.loadExposure(movie: false) }
        .onDisappear { model.stop() }
        .onChange(of: model.state.frameSequence) { _ in updateZebraMask() }
        .onChange(of: zebraVisible) { _ in updateZebraMask(force: true) }
        .sheet(item: $selectedField) { field in
            ExposureValueList(field: field, descriptor: model.exposureDescriptors[field]) { value in
                model.setExposure(field, value: value)
                selectedField = nil
            }
        }
    }

    private func updateZebraMask(force: Bool = false) {
        guard zebraVisible, let image = model.frameImage else {
            zebraMask = nil
            return
        }
        let now = CACurrentMediaTime()
        guard force || now - lastZebraUpdate >= 0.25 else { return }
        lastZebraUpdate = now
        zebraMask = IOSZebraMask(image: image)
    }

    private func fitImageRect(in size: CGSize, aspect: CGFloat) -> CGRect {
        guard aspect > 0, size.width > 0, size.height > 0 else { return .zero }
        let fitted = min(size.width / aspect, size.height)
        let width = fitted * aspect
        return CGRect(x: (size.width - width) / 2, y: (size.height - fitted) / 2,
                      width: width, height: fitted)
    }

    private var sessionFailed: Bool {
        if case .failed = model.state.session { return true }
        return false
    }

    private var exposureGrid: some View {
        let fields: [RemoteExposureField] = [.exposureCompensation, .iso, .aperture, .shutter]
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(fields, id: \.self) { field in
                RemoteExposureTile(field: field, descriptor: model.exposureDescriptors[field],
                                   onOpenList: { selectedField = field },
                                   onCommit: { model.setExposure(field, value: $0) },
                                   autoEnabled: field == .iso ? model.autoISOEnabled : nil,
                                   autoToggle: field == .iso && model.autoISODescriptor != nil ?
                                       { model.setAutoISO(!model.autoISOEnabled) } : nil)
            }
        }
        .padding(.horizontal, 14)
        .foregroundStyle(.white)
    }
}

private struct RemoteStatusBadge: View {
    let text: String
    let weight: Font.Weight

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: weight))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct RemoteFocusReticle: View {
    let phase: RemoteFocusPhase
    let point: RemoteFocusPoint
    let nonce: UInt64
    let aspect: CGFloat
    @State private var scale: CGFloat = 1.35

    var body: some View {
        GeometryReader { proxy in
            let fitted = min(proxy.size.width / max(aspect, 0.01), proxy.size.height)
            let rect = CGRect(x: (proxy.size.width - fitted * aspect) / 2,
                              y: (proxy.size.height - fitted) / 2,
                              width: fitted * aspect, height: fitted)
            let center = CGPoint(x: rect.minX + rect.width * point.x,
                                 y: rect.minY + rect.height * point.y)
            let color: Color = switch phase {
            case .locked: .green
            case .failed: .red
            default: .cyan
            }
            Rectangle()
                .stroke(color, lineWidth: 2)
                .frame(width: 64, height: 64)
                .scaleEffect(scale)
                .position(center)
                .opacity(phase == .failed ? 0.75 : 1)
                .onAppear {
                    scale = 1.35
                    withAnimation(.easeOut(duration: 0.18)) { scale = 1 }
                }
                .onChange(of: nonce) { _ in
                    scale = 1.35
                    withAnimation(.easeOut(duration: 0.18)) { scale = 1 }
                }
        }
        .allowsHitTesting(false)
    }
}

private struct RemoteHistogramOverlay: View {
    let image: UIImage
    var body: some View {
        Canvas { context, size in
            let bins = histogramBins()
            let maxValue = max(1, bins.max() ?? 1)
            for (index, value) in bins.enumerated() {
                let width = size.width / CGFloat(bins.count)
                let height = size.height * CGFloat(value) / CGFloat(maxValue)
                let rect = CGRect(x: CGFloat(index) * width,
                                  y: size.height - height,
                                  width: max(1, width - 0.5), height: height)
                context.fill(Path(rect), with: .color(.white.opacity(0.78)))
            }
        }
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
    }

    private func histogramBins() -> [Int] {
        guard let cg = image.cgImage, let provider = cg.dataProvider,
              let data = provider.data as Data?, cg.bitsPerComponent == 8 else { return Array(repeating: 0, count: 24) }
        let bytes = [UInt8](data)
        let channels = cg.bitsPerPixel / 8
        guard channels >= 3 else { return Array(repeating: 0, count: 24) }
        var bins = Array(repeating: 0, count: 24)
        let step = max(channels, bytes.count / 4096)
        var index = 0
        while index + 2 < bytes.count {
            let luminance = (Int(bytes[index]) * 299 + Int(bytes[index + 1]) * 587 + Int(bytes[index + 2]) * 114) / 1000
            bins[min(23, luminance * 24 / 256)] += 1
            index += step
        }
        return bins
    }
}

private enum IOSViewfinderGrid: Equatable {
    case off, thirds, fourths

    var divisions: Int {
        switch self {
        case .off: 0
        case .thirds: 3
        case .fourths: 4
        }
    }

    var next: Self {
        switch self {
        case .off: .thirds
        case .thirds: .fourths
        case .fourths: .off
        }
    }
}

private struct IOSFramingGridOverlay: View {
    let divisions: Int
    let aspect: CGFloat

    var body: some View {
        Canvas { context, size in
            guard divisions > 1 else { return }
            let stroke = StrokeStyle(lineWidth: 0.75, lineCap: .round)
            let color = Color.white.opacity(0.42)
            let fittedHeight = min(size.width / max(aspect, 0.01), size.height)
            let fittedWidth = fittedHeight * aspect
            let rect = CGRect(x: (size.width - fittedWidth) / 2,
                              y: (size.height - fittedHeight) / 2,
                              width: fittedWidth, height: fittedHeight)
            for index in 1..<divisions {
                let fraction = CGFloat(index) / CGFloat(divisions)
                var vertical = Path()
                vertical.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY))
                vertical.addLine(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
                context.stroke(vertical, with: .color(color), style: stroke)
                var horizontal = Path()
                horizontal.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
                horizontal.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
                context.stroke(horizontal, with: .color(color), style: stroke)
            }
        }
    }
}

/// Android computes zebra blocks from the decoded frame, throttled to 250 ms.
/// iOS keeps the same 120×80 center-sample mask and 95 IRE threshold.
private struct IOSZebraMask {
    let cols: Int
    let rows: Int
    let cells: [Bool]

    init?(image: UIImage) {
        guard let cg = image.cgImage,
              cg.bitsPerComponent == 8,
              cg.bitsPerPixel >= 24,
              let provider = cg.dataProvider,
              let providerData = provider.data as Data? else { return nil }
        let width = max(1, cg.width)
        let height = max(1, cg.height)
        let cellWidth = max(1, (width + 119) / 120)
        let cellHeight = max(1, (height + 79) / 80)
        let computedCols = (width + cellWidth - 1) / cellWidth
        let computedRows = (height + cellHeight - 1) / cellHeight
        var result = Array(repeating: false, count: computedCols * computedRows)
        let bytesPerPixel = max(3, cg.bitsPerPixel / 8)
        let rowStride = cg.bytesPerRow
        let littleEndian = cg.byteOrderInfo == .order32Little
        providerData.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for row in 0..<computedRows {
                let y = min(height - 1, row * cellHeight + cellHeight / 2)
                var column = 0
                while column < computedCols {
                    let x = min(width - 1, column * cellWidth + cellWidth / 2)
                    let pixel = base.advanced(by: y * rowStride + x * bytesPerPixel)
                    let red: Int
                    let green: Int
                    let blue: Int
                    if littleEndian && bytesPerPixel >= 4 {
                        blue = Int(pixel[0]); green = Int(pixel[1]); red = Int(pixel[2])
                    } else {
                        red = Int(pixel[0]); green = Int(pixel[1]); blue = Int(pixel[2])
                    }
                    let luma = (54 * red + 183 * green + 19 * blue) >> 8
                    result[row * computedCols + column] = luma >= 242
                    column += 1
                }
            }
        }
        cols = computedCols
        rows = computedRows
        cells = result
    }
}

private struct IOSZebraOverlay: View {
    let mask: IOSZebraMask
    let aspect: CGFloat

    var body: some View {
        Canvas { context, size in
            let fittedHeight = min(size.width / max(aspect, 0.01), size.height)
            let fittedWidth = fittedHeight * aspect
            let rect = CGRect(x: (size.width - fittedWidth) / 2,
                              y: (size.height - fittedHeight) / 2,
                              width: fittedWidth, height: fittedHeight)
            guard rect.width > 0, rect.height > 0 else { return }
            let cellWidth = rect.width / CGFloat(mask.cols)
            let cellHeight = rect.height / CGFloat(mask.rows)
            var clip = Path()
            for row in 0..<mask.rows {
                for column in 0..<mask.cols where mask.cells[row * mask.cols + column] {
                    clip.addRect(CGRect(x: rect.minX + CGFloat(column) * cellWidth,
                                        y: rect.minY + CGFloat(row) * cellHeight,
                                        width: cellWidth, height: cellHeight))
                }
            }
            var white = Path()
            var black = Path()
            let period: CGFloat = 5
            var x = rect.minX - rect.height
            while x < rect.maxX {
                white.move(to: CGPoint(x: x, y: rect.maxY))
                white.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                let half = x + period / 2
                black.move(to: CGPoint(x: half, y: rect.maxY))
                black.addLine(to: CGPoint(x: half + rect.height, y: rect.minY))
                x += period
            }
            context.drawLayer { layer in
                layer.clip(to: clip)
                layer.stroke(black, with: .color(.black.opacity(0.50)),
                             style: StrokeStyle(lineWidth: 1.4))
                layer.stroke(white, with: .color(.white.opacity(0.85)),
                             style: StrokeStyle(lineWidth: 1.4))
            }
        }
    }
}

private struct IOSFocusFrameOverlay: View {
    let frame: RemoteLiveViewFocusFrame
    let aspect: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let fitted = min(proxy.size.width / max(aspect, 0.01), proxy.size.height)
            let imageWidth = fitted * aspect
            let imageRect = CGRect(x: (proxy.size.width - imageWidth) / 2,
                                   y: (proxy.size.height - fitted) / 2,
                                   width: imageWidth, height: fitted)
            let rect = CGRect(x: imageRect.minX + imageRect.width * CGFloat(frame.centerX - frame.width / 2),
                              y: imageRect.minY + imageRect.height * CGFloat(frame.centerY - frame.height / 2),
                              width: imageRect.width * CGFloat(frame.width),
                              height: imageRect.height * CGFloat(frame.height))
            let corner = min(rect.width, rect.height) * 0.24
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.minY + corner))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX + corner, y: rect.minY))
                path.move(to: CGPoint(x: rect.maxX - corner, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + corner))
                path.move(to: CGPoint(x: rect.minX, y: rect.maxY - corner))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX + corner, y: rect.maxY))
                path.move(to: CGPoint(x: rect.maxX - corner, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - corner))
            }
            .stroke(.green, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}

private struct IOSSoundMeter: View {
    let levels: RemoteLiveViewSoundLevels

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            meter(levels.currentLeft, peak: levels.peakLeft)
            meter(levels.currentRight, peak: levels.peakRight)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(.black.opacity(0.56), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.14), lineWidth: 0.5))
    }

    private func meter(_ current: Int, peak: Int) -> some View {
        VStack(spacing: 2) {
            ForEach((0...Int(RemoteLiveViewSoundLevels.maxSegment)).reversed(), id: \.self) { segment in
                Capsule()
                    .fill(segment <= peak ? (segment >= 12 ? .red : segment >= 9 ? .yellow : .green) : .white.opacity(0.16))
                    .frame(width: 7, height: 5)
                    .opacity(segment <= current ? 1 : 0.42)
            }
        }
    }
}

private extension RemoteExposureField {
    var label: String {
        switch self {
        case .exposureCompensation: return "EV"
        case .iso: return "ISO"
        case .aperture: return "f"
        case .shutter: return "S"
        }
    }
}

private struct ExposureValueList: View {
    let field: RemoteExposureField
    let descriptor: RemotePropertyDescriptor?
    let onSelect: (UInt64) -> Void

    var body: some View {
        NavigationStack {
            List(descriptor?.values ?? [], id: \.self) { value in
                Button(RemoteExposureParameters.format(descriptor?.property ?? .iso, raw: value)) {
                    onSelect(value)
                }
            }
            .navigationTitle(field.label)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
