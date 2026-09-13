import SwiftUI
import UIKit

/// Native monitor surface. Transport and frame lifecycle live in
/// `RemoteViewModel`; this view only renders the camera frame and the controls
/// that are already present in Android's RemoteScreen.
struct RemoteView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: RemoteViewModel
    @State private var zoom: CGFloat = 1
    @State private var selectedField: RemoteExposureField?
    @AppStorage("remote.desqueeze") private var desqueeze = 1.0
    @AppStorage("remote.histogram") private var histogramVisible = false
    @AppStorage("remote.level") private var levelVisible = false

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
        .sheet(item: $selectedField) { field in
            ExposureValueList(field: field, descriptor: model.exposureDescriptors[field]) { value in
                model.setExposure(field, value: value)
                selectedField = nil
            }
        }
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
