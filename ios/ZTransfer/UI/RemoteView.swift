import SwiftUI
import UIKit
import QuartzCore

private enum RemoteLayoutOrientation: Equatable {
    case portrait
    case landscapeLeft
    case landscapeRight

    var isLandscape: Bool {
        self != .portrait
    }

    var rotationDegrees: Double {
        switch self {
        case .portrait: 0
        case .landscapeLeft: 90
        case .landscapeRight: -90
        }
    }
}

private struct RemoteToolTintKey: EnvironmentKey {
    static let defaultValue = ZTransferColors.secondaryText
}

private extension EnvironmentValues {
    var remoteToolTint: Color {
        get { self[RemoteToolTintKey.self] }
        set { self[RemoteToolTintKey.self] = newValue }
    }
}

/// Native monitor surface. Transport and frame lifecycle live in
/// `RemoteViewModel`; this view only renders the camera frame and the controls
/// that are already present in Android's RemoteScreen.
struct RemoteView: View {
    @Environment(\.dismiss) private var dismiss
    private let onStopped: ((Bool) -> Void)?
    private let onTransportLost: (() -> Void)?
    private let isSessionConnected: Bool
    private let onRetrySTA: () -> Void
    private let isUSBSession: Bool
    private let wirelessMode: WirelessMode?
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
    @State private var recordingDotDimmed = false
    @State private var layoutOrientation: RemoteLayoutOrientation = .portrait
    @State private var orientationNotificationsActive = false
    @State private var stopCleanupStarted = false

    init(session: CameraSession, isSessionConnected: Bool = true,
         onRetrySTA: @escaping () -> Void = {}, onStopped: ((Bool) -> Void)? = nil,
         onTransportLost: (() -> Void)? = nil) {
        self.onStopped = onStopped
        self.onTransportLost = onTransportLost
        self.isSessionConnected = isSessionConnected
        self.onRetrySTA = onRetrySTA
        self.isUSBSession = session.isUSB
        self.wirelessMode = session.wirelessMode
        _model = StateObject(wrappedValue: RemoteViewModel(camera: session,
                                                            onTransportLost: onTransportLost))
    }

    var body: some View {
        ZStack {
            ZTransferColors.background.ignoresSafeArea()
            GeometryReader { proxy in
                if layoutOrientation.isLandscape {
                    landscapeRemoteLayout
                        // Android keeps the host portrait and rotates a measured
                        // landscape canvas inside it, so system bars stay put.
                        .frame(width: proxy.size.height, height: proxy.size.width)
                        .rotationEffect(.degrees(layoutOrientation.rotationDegrees))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .transition(.opacity)
                } else {
                    portraitRemoteLayout
                        .transition(.opacity)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let hint = model.recordingHint {
                Text(hint)
                    .font(.system(size: 14, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(ZTransferColors.primaryText)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 28)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(ZTransferMotion.standard, value: model.recordingHint)
        .animation(ZTransferMotion.standard, value: layoutOrientation)
        .statusBarHidden(false)
        .task { model.start() }
        .task { model.loadExposure(movie: false) }
        // Orientation is intentionally scoped to the monitor page. The rest
        // of the app stays portrait; this page rotates its own canvas to match
        // the device instead of changing the application's interface size.
        .onAppear {
            guard !orientationNotificationsActive else { return }
            orientationNotificationsActive = true
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            applyDeviceOrientation(UIDevice.current.orientation)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { notification in
            guard let device = notification.object as? UIDevice else { return }
            applyDeviceOrientation(device.orientation)
        }
        .onDisappear {
            guard !stopCleanupStarted else { return }
            stopCleanupStarted = true
            if orientationNotificationsActive {
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
                orientationNotificationsActive = false
            }
            Task { @MainActor in
                await model.stopAndWait()
                onStopped?(model.transportLossWasNotified)
            }
        }
        .onChange(of: model.state.frameSequence) { _ in updateZebraMask() }
        .onChange(of: zebraVisible) { _ in updateZebraMask(force: true) }
        .sheet(item: $selectedField) { field in
            ExposureValueList(field: field, descriptor: model.exposureDescriptors[field]) { value in
                model.setExposure(field, value: value)
                selectedField = nil
            }
        }
    }

    private var portraitRemoteLayout: some View {
        VStack(spacing: 0) {
            remoteTopBar
                .padding(.horizontal, 14)
                .padding(.top, 8)

            Spacer().frame(height: 12)

            remoteViewfinder
                .padding(.horizontal, 14)

            Spacer().frame(height: 10)

            portraitToolRows
                .padding(.horizontal, 14)

            Spacer().frame(height: 12)

            exposureGrid

            Spacer(minLength: 18)

            shutterButton
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var landscapeRemoteLayout: some View {
        GeometryReader { proxy in
            HStack(spacing: 10) {
                VStack(spacing: 10) {
                    // Android's landscape monitor keeps the complete tool strip
                    // under the viewfinder. It is a horizontal strip, never a
                    // vertical rail beside the image.
                    remoteViewfinder
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    landscapeToolBar
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 12) {
                    Spacer(minLength: 28)
                    exposureGrid
                        .frame(width: 178)
                    Spacer(minLength: 12)
                    shutterButton
                    Spacer(minLength: 16)
                }
                .frame(width: 178, height: proxy.size.height)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .overlay(alignment: .topTrailing) {
                landscapeRemoteTopBar
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    private var remoteTopBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                remoteSignalButton
                remoteBatteryButton
            }
            Spacer(minLength: 0)
            remoteBackButton
        }
    }

    /// Android's landscape toolbar keeps all three fixed controls together at
    /// the trailing edge: signal, battery, then the return button.
    private var landscapeRemoteTopBar: some View {
        HStack(spacing: 8) {
            remoteSignalButton
            remoteBatteryButton
            remoteBackButton
        }
    }

    private var remoteBackButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "arrow.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(ZTransferColors.primaryText)
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(0.86), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.95), lineWidth: 1))
                .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppLocalized.resource("cd_back"))
    }

    private var remoteSignalButton: some View {
        Button {
            if wirelessMode == .sta && !isSessionConnected { onRetrySTA() }
        } label: {
            HStack {
                PhotoListSignalIcon(isUSB: isUSBSession, wirelessMode: wirelessMode,
                                    connected: isSessionConnected)
                    .frame(width: 19, height: 19)
            }
            .frame(width: 40, height: 36)
            .background(Color.white.opacity(0.86), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.95), lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppLocalized.resource(wirelessMode == .sta && !isSessionConnected
                                                  ? "sta_signal_disconnected_reconnect" : "sta_signal_connected"))
    }

    private var remoteBatteryButton: some View {
        HStack(spacing: 5) {
            RemoteBatteryIcon()
                .frame(width: 21, height: 15)
        }
        .frame(width: 48, height: 36)
        .background(Color.white.opacity(0.86), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.95), lineWidth: 1))
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        .accessibilityLabel(AppLocalized.resource("cd_camera_battery"))
    }

    private var portraitToolRows: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                remoteToolButton(active: model.hdLiveView, label: { Text("HD").font(.system(size: 13, weight: .bold)).fixedSize() }) {
                    withAnimation(ZTransferMotion.standard) {
                        model.setHDLiveView(!model.hdLiveView)
                    }
                }
                remoteToolButton(active: showFps, label: { Text("FPS").font(.system(size: 10.5, weight: .bold)).fixedSize() }) {
                    withAnimation(ZTransferMotion.standard) { showFps.toggle() }
                }
                remoteToolButton(active: histogramVisible, label: { RemoteHistogramIcon().frame(width: 19, height: 19) }) {
                    withAnimation(ZTransferMotion.standard) { histogramVisible.toggle() }
                }
                remoteToolButton(active: framingGrid != .off, label: { RemoteGridIcon().frame(width: 18, height: 18) }) {
                    withAnimation(ZTransferMotion.standard) { framingGrid = framingGrid.next }
                }
                remoteToolButton(active: zebraVisible, label: { RemoteZebraIcon().frame(width: 18, height: 18) }) {
                    withAnimation(ZTransferMotion.standard) { zebraVisible.toggle() }
                }
                remoteToolButton(active: desqueeze > 1.001, label: { RemoteAspectIcon().frame(width: 18, height: 18) }) {
                    withAnimation(ZTransferMotion.standard) {
                        desqueeze = RemoteDisplayOptions.nextDesqueeze(after: desqueeze)
                    }
                }
                remoteToolButton(active: levelVisible, label: { RemoteLevelIcon().frame(width: 18, height: 18) }) {
                    withAnimation(ZTransferMotion.standard) { levelVisible.toggle() }
                }
                remoteToolButton(active: false, label: { RemoteFullscreenIcon().frame(width: 17, height: 17) }) {
                    withAnimation(ZTransferMotion.standard) { layoutOrientation = .landscapeLeft }
                }
                remoteToolButton(active: layoutOrientation.isLandscape, label: { RemoteRotateIcon().frame(width: 20, height: 20) }) {
                    cycleLayoutOrientation()
                }
            }
            HStack(spacing: 8) {
                if model.movieMode {
                    remoteToolButton(active: audioLevelsVisible, label: { RemoteAudioIcon().frame(width: 18, height: 18) }) {
                        withAnimation(ZTransferMotion.standard) { audioLevelsVisible.toggle() }
                    }
                    remoteRecordButton
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var landscapeToolBar: some View {
        HStack(spacing: 7) {
            remoteToolButton(active: model.hdLiveView, label: { Text("HD").font(.system(size: 13, weight: .bold)).fixedSize() }) {
                withAnimation(ZTransferMotion.standard) { model.setHDLiveView(!model.hdLiveView) }
            }
            remoteToolButton(active: showFps, label: { Text("FPS").font(.system(size: 10.5, weight: .bold)).fixedSize() }) {
                withAnimation(ZTransferMotion.standard) { showFps.toggle() }
            }
            if model.movieMode {
                remoteToolButton(active: audioLevelsVisible, label: { RemoteAudioIcon().frame(width: 18, height: 18) }) {
                    withAnimation(ZTransferMotion.standard) { audioLevelsVisible.toggle() }
                }
            }
            remoteToolButton(active: histogramVisible, label: { RemoteHistogramIcon().frame(width: 19, height: 19) }) {
                withAnimation(ZTransferMotion.standard) { histogramVisible.toggle() }
            }
            remoteToolButton(active: framingGrid != .off, label: { RemoteGridIcon().frame(width: 18, height: 18) }) {
                withAnimation(ZTransferMotion.standard) { framingGrid = framingGrid.next }
            }
            remoteToolButton(active: zebraVisible, label: { RemoteZebraIcon().frame(width: 18, height: 18) }) {
                withAnimation(ZTransferMotion.standard) { zebraVisible.toggle() }
            }
            remoteToolButton(active: desqueeze > 1.001, label: { RemoteAspectIcon().frame(width: 18, height: 18) }) {
                withAnimation(ZTransferMotion.standard) {
                    desqueeze = RemoteDisplayOptions.nextDesqueeze(after: desqueeze)
                }
            }
            remoteToolButton(active: levelVisible, label: { RemoteLevelIcon().frame(width: 18, height: 18) }) {
                withAnimation(ZTransferMotion.standard) { levelVisible.toggle() }
            }
            if model.movieMode {
                remoteRecordButton
            }
            remoteToolButton(active: false, label: { RemoteFullscreenIcon().frame(width: 17, height: 17) }) {
                withAnimation(ZTransferMotion.standard) { layoutOrientation = .portrait }
            }
            remoteToolButton(active: true, label: { RemoteRotateIcon().frame(width: 20, height: 20) }) {
                cycleLayoutOrientation()
            }
        }
    }

    private var remoteRecordButton: some View {
        Button { model.toggleRecording() } label: {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.86))
                    .overlay(Circle().stroke(Color.white.opacity(0.95), lineWidth: 1))
                Circle()
                    .fill(model.state.capture == .recording ? ZTransferColors.statusError : ZTransferColors.statusError.opacity(0.9))
                    .frame(width: 19, height: 19)
            }
            .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .disabled(!model.movieMode || model.recordingBusy)
        .opacity(model.movieMode ? 1 : 0.45)
        .accessibilityLabel(AppLocalized.resource("cd_remote_rec_start"))
    }

    private func remoteToolButton<Label: View>(
        active: Bool,
        @ViewBuilder label: @escaping () -> Label,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            label()
                .foregroundStyle(active ? ZTransferColors.accentBlue : ZTransferColors.secondaryText)
                .environment(\.remoteToolTint, active ? ZTransferColors.accentBlue : ZTransferColors.secondaryText)
                .frame(minWidth: 20, minHeight: 20)
                .frame(width: 36, height: 36)
                .background(active ? ZTransferColors.accentBlue.opacity(0.16) : Color.white.opacity(0.86),
                            in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.95), lineWidth: 1))
                .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
    }

    private var shutterButton: some View {
        Button {
            if model.movieMode { model.toggleRecording() } else { model.capture() }
        } label: {
            ZStack {
                Circle().stroke(ZTransferColors.primaryText.opacity(0.88), lineWidth: 4)
                    .frame(width: 82, height: 82)
                RoundedRectangle(cornerRadius: model.state.capture == .recording ? 8 : 41)
                    .fill(model.movieMode ? ZTransferColors.statusError : Color.white)
                    .frame(width: model.state.capture == .recording ? 30 : 64,
                           height: model.state.capture == .recording ? 30 : 64)
                    .animation(ZTransferMotion.emphasized, value: model.state.capture)
            }
        }
        .buttonStyle(.plain)
        .disabled(model.state.session != .ready || model.recordingBusy)
        .opacity(model.state.session == .ready ? 1 : 0.72)
        .accessibilityLabel(AppLocalized.resource("cd_remote_entry"))
    }

    private var remoteViewfinder: some View {
        GeometryReader { proxy in
            let image = model.frameImage
            let aspect = image.map { ($0.size.width / max($0.size.height, 1)) * CGFloat(desqueeze) } ?? 1.5
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(RadialGradient(
                        colors: [Color(white: 0.38), Color(white: 0.18)],
                        center: .center,
                        startRadius: 12,
                        endRadius: 420
                    ))
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(aspect, contentMode: .fit)
                        .scaleEffect(x: CGFloat(desqueeze), y: 1, anchor: .center)
                        .scaleEffect(zoom)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            MagnificationGesture()
                                .onChanged { value in zoom = min(max(value, 1), 4) }
                                .onEnded { _ in withAnimation(ZTransferMotion.standard) { zoom = min(max(zoom, 1), 4) } }
                        )
                        .simultaneousGesture(
                            SpatialTapGesture().onEnded { value in
                                let rect = fitImageRect(in: proxy.size, aspect: aspect)
                                guard rect.contains(value.location) else { return }
                                let x = Double((value.location.x - rect.minX) / rect.width)
                                let y = Double((value.location.y - rect.minY) / rect.height)
                                model.focus(at: RemoteFocusPoint(x: x, y: y), coordinateSize: image.size)
                            }
                        )
                }
                if let image {
                    if let point = model.state.focus.point,
                       model.state.focus.phase != .idle {
                        RemoteFocusReticle(phase: model.state.focus.phase,
                                           point: point,
                                           nonce: model.state.focus.nonce,
                                           aspect: aspect)
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
                        IOSFramingGridOverlay(divisions: framingGrid.divisions, aspect: aspect)
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
                        IOSFocusFrameOverlay(frame: focusFrame, aspect: aspect)
                            .allowsHitTesting(false)
                    }
                    if zebraVisible, let zebraMask {
                        IOSZebraOverlay(mask: zebraMask, aspect: aspect)
                            .allowsHitTesting(false)
                    }
                }
                if showFps, model.state.fps > 0 {
                    Text(String(format: "%.1f fps", model.state.fps))
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(10)
                        .allowsHitTesting(false)
                }
                if model.state.liveViewStable {
                    HStack(spacing: 4) {
                        RemoteStatusBadge(text: "M", weight: .bold)
                        if let focusMode = model.focusModeDescriptor {
                            RemoteStatusBadge(text: focusMode.current == 1 ? "MF" : "AF-S", weight: .semibold)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(10)
                    .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .aspectRatio(remoteViewfinderAspect, contentMode: .fit)
    }

    private var remoteViewfinderAspect: CGFloat {
        guard let image = model.frameImage else { return 1.5 }
        return (image.size.width / max(image.size.height, 1)) * CGFloat(desqueeze)
    }

    private struct RemoteBatteryIcon: View {
        var body: some View {
            Canvas { context, size in
                let body = CGRect(x: 1, y: 2, width: size.width - 5, height: size.height - 4)
                context.stroke(Path(roundedRect: body, cornerRadius: 3),
                               with: .color(ZTransferColors.accentOrange), lineWidth: 2)
                context.fill(Path(roundedRect: CGRect(x: body.minX + 3, y: body.minY + 3,
                                                       width: max(CGFloat(2), body.width * 0.19), height: body.height - 6),
                                  cornerRadius: 1.5),
                             with: .color(ZTransferColors.accentOrange))
                context.fill(Path(roundedRect: CGRect(x: body.maxX, y: size.height * 0.34,
                                                       width: 4, height: size.height * 0.32),
                                  cornerRadius: 1),
                             with: .color(ZTransferColors.accentOrange))
            }
        }
    }

    private struct RemoteHistogramIcon: View {
        @Environment(\.remoteToolTint) private var tint

        var body: some View {
            Canvas { context, size in
                let barWidth = (size.width - 7) / 5
                let gap: CGFloat = 1.5
                let heights: [CGFloat] = [0.38, 0.62, 0.85, 0.55, 0.28]
                let baseY = size.height - 2
                for (index, height) in heights.enumerated() {
                    var bar = Path()
                    let x = 2.5 + CGFloat(index) * (barWidth + gap)
                    bar.move(to: CGPoint(x: x, y: baseY))
                    bar.addLine(to: CGPoint(x: x, y: baseY - baseY * height))
                    context.stroke(bar, with: .color(tint),
                                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
            }
        }
    }

    private struct RemoteGridIcon: View {
        @Environment(\.remoteToolTint) private var tint

        var body: some View {
            Canvas { context, size in
                let stroke = StrokeStyle(lineWidth: 1.5, lineCap: .round)
                let inset: CGFloat = 2
                for x in [CGFloat(0.30), CGFloat(0.70)] {
                    var path = Path()
                    let coordinate = inset + (size.width - inset * 2) * x
                    path.move(to: CGPoint(x: coordinate, y: inset))
                    path.addLine(to: CGPoint(x: coordinate, y: size.height - inset))
                    context.stroke(path, with: .color(tint), style: stroke)
                }
                for y in [CGFloat(0.30), CGFloat(0.70)] {
                    var path = Path()
                    let coordinate = inset + (size.height - inset * 2) * y
                    path.move(to: CGPoint(x: inset, y: coordinate))
                    path.addLine(to: CGPoint(x: size.width - inset, y: coordinate))
                    context.stroke(path, with: .color(tint), style: stroke)
                }
            }
        }
    }

    private struct RemoteZebraIcon: View {
        @Environment(\.remoteToolTint) private var tint

        var body: some View {
            Canvas { context, size in
                let stroke = StrokeStyle(lineWidth: 1.5, lineCap: .round)
                for index in 0..<5 {
                    let x = size.width * ((CGFloat(index) + 1) / 6)
                    let d = size.height * 0.24
                    var path = Path()
                    path.move(to: CGPoint(x: x - d, y: size.height * 0.5 - d))
                    path.addLine(to: CGPoint(x: x + d, y: size.height * 0.5 + d))
                    context.stroke(path, with: .color(tint), style: stroke)
                }
            }
        }
    }

    private struct RemoteAspectIcon: View {
        @Environment(\.remoteToolTint) private var tint

        var body: some View {
            Canvas { context, size in
                // Material Icons.Outlined.AspectRatio, matching Android's
                // four-corner crop glyph rather than a generic expand arrow.
                let sx = size.width / 24
                let sy = size.height / 24
                context.scaleBy(x: sx, y: sy)
                let stroke = StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                var frame = Path()
                frame.addRect(CGRect(x: 4, y: 4, width: 16, height: 16))
                context.stroke(frame, with: .color(tint), style: stroke)
                var corners = Path()
                corners.move(to: CGPoint(x: 8, y: 8)); corners.addLine(to: CGPoint(x: 11, y: 8))
                corners.move(to: CGPoint(x: 8, y: 8)); corners.addLine(to: CGPoint(x: 8, y: 11))
                corners.move(to: CGPoint(x: 16, y: 16)); corners.addLine(to: CGPoint(x: 13, y: 16))
                corners.move(to: CGPoint(x: 16, y: 16)); corners.addLine(to: CGPoint(x: 16, y: 13))
                context.stroke(corners, with: .color(tint), style: stroke)
            }
        }
    }

    private struct RemoteFullscreenIcon: View {
        @Environment(\.remoteToolTint) private var tint

        var body: some View {
            Canvas { context, size in
                let stroke = StrokeStyle(lineWidth: 1.5, lineCap: .round)
                // Android uses a 2dp inset and 5dp arms in a 17dp mark.
                let pad: CGFloat = 2
                let arm: CGFloat = 5
                let segments: [(CGPoint, CGPoint)] = [
                    (CGPoint(x: pad, y: pad), CGPoint(x: pad + arm, y: pad)),
                    (CGPoint(x: pad, y: pad), CGPoint(x: pad, y: pad + arm)),
                    (CGPoint(x: size.width - pad, y: pad), CGPoint(x: size.width - pad - arm, y: pad)),
                    (CGPoint(x: size.width - pad, y: pad), CGPoint(x: size.width - pad, y: pad + arm)),
                    (CGPoint(x: pad, y: size.height - pad), CGPoint(x: pad + arm, y: size.height - pad)),
                    (CGPoint(x: pad, y: size.height - pad), CGPoint(x: pad, y: size.height - pad - arm)),
                    (CGPoint(x: size.width - pad, y: size.height - pad), CGPoint(x: size.width - pad - arm, y: size.height - pad)),
                    (CGPoint(x: size.width - pad, y: size.height - pad), CGPoint(x: size.width - pad, y: size.height - pad - arm)),
                ]
                for (start, end) in segments {
                    var path = Path()
                    path.move(to: start)
                    path.addLine(to: end)
                    context.stroke(path, with: .color(tint), style: stroke)
                }
            }
        }
    }

    private struct RemoteRotateIcon: View {
        @Environment(\.remoteToolTint) private var tint

        var body: some View {
            Canvas { context, size in
                // Match Android's 20dp RotateMark: 225° open arc plus one
                // outer arrow wing at the arc tangent.
                let side = min(size.width, size.height)
                let center = CGPoint(x: size.width * 0.5, y: size.height * 0.49)
                let radius = side * 0.29
                let stroke = StrokeStyle(lineWidth: 1.5, lineCap: .round)
                var arc = Path()
                arc.addArc(center: center, radius: radius,
                           startAngle: .degrees(-125), endAngle: .degrees(100), clockwise: false)
                context.stroke(arc, with: .color(tint), style: stroke)
                let endAngle = 100.0 * Double.pi / 180.0
                let tip = CGPoint(x: center.x + cos(endAngle) * radius,
                                  y: center.y + sin(endAngle) * radius)
                let wingAngle = (100.0 + 90.0 + 180.0 + 32.0) * Double.pi / 180.0
                let arrowLength = side * 0.16
                let wingEnd = CGPoint(x: tip.x + cos(wingAngle) * arrowLength,
                                      y: tip.y + sin(wingAngle) * arrowLength)
                var wing = Path()
                wing.move(to: tip)
                wing.addLine(to: wingEnd)
                context.stroke(wing, with: .color(tint), style: stroke)
            }
        }
    }

    private struct RemoteAudioIcon: View {
        @Environment(\.remoteToolTint) private var tint

        var body: some View {
            Canvas { context, size in
                let sx = size.width / 24
                let sy = size.height / 24
                context.scaleBy(x: sx, y: sy)
                var speaker = Path()
                speaker.move(to: CGPoint(x: 3, y: 9)); speaker.addLine(to: CGPoint(x: 7, y: 9))
                speaker.addLine(to: CGPoint(x: 12, y: 4)); speaker.addLine(to: CGPoint(x: 12, y: 20))
                speaker.addLine(to: CGPoint(x: 7, y: 15)); speaker.addLine(to: CGPoint(x: 3, y: 15)); speaker.closeSubpath()
                context.fill(speaker, with: .color(tint))
                let wave = StrokeStyle(lineWidth: 1.7, lineCap: .round)
                var near = Path(); near.addArc(center: CGPoint(x: 12, y: 12), radius: 4,
                                                startAngle: .degrees(-48), endAngle: .degrees(48), clockwise: false)
                var far = Path(); far.addArc(center: CGPoint(x: 12, y: 12), radius: 7,
                                              startAngle: .degrees(-48), endAngle: .degrees(48), clockwise: false)
                context.stroke(near, with: .color(tint), style: wave)
                context.stroke(far, with: .color(tint), style: wave)
            }
        }
    }

    private struct RemoteLevelIcon: View {
        @Environment(\.remoteToolTint) private var tint

        var body: some View {
            Canvas { context, size in
                let left = size.width * 0.08, right = size.width * 0.92
                let top = size.height * 0.24, bottom = size.height * 0.78
                let corner = min(size.width, size.height) * 0.09
                let vialLeft = size.width * 0.34, vialRight = size.width * 0.66
                let vialBottom = size.height * 0.49
                var body = Path()
                body.move(to: CGPoint(x: left + corner, y: top))
                body.addLine(to: CGPoint(x: vialLeft, y: top))
                body.addCurve(to: CGPoint(x: vialRight, y: top),
                              control1: CGPoint(x: vialLeft, y: vialBottom),
                              control2: CGPoint(x: vialRight, y: vialBottom))
                body.addLine(to: CGPoint(x: right - corner, y: top))
                body.addQuadCurve(to: CGPoint(x: right, y: top + corner),
                                  control: CGPoint(x: right, y: top))
                body.addLine(to: CGPoint(x: right, y: bottom - corner))
                body.addQuadCurve(to: CGPoint(x: right - corner, y: bottom),
                                  control: CGPoint(x: right, y: bottom))
                body.addLine(to: CGPoint(x: left + corner, y: bottom))
                body.addQuadCurve(to: CGPoint(x: left, y: bottom - corner),
                                  control: CGPoint(x: left, y: bottom))
                body.addLine(to: CGPoint(x: left, y: top + corner))
                body.addQuadCurve(to: CGPoint(x: left + corner, y: top),
                                  control: CGPoint(x: left, y: top))
                body.closeSubpath()
                let stroke = StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round)
                context.stroke(body, with: .color(tint), style: stroke)
                var dividers = Path()
                dividers.move(to: CGPoint(x: size.width * 0.27, y: top))
                dividers.addLine(to: CGPoint(x: size.width * 0.27, y: bottom))
                dividers.move(to: CGPoint(x: size.width * 0.73, y: top))
                dividers.addLine(to: CGPoint(x: size.width * 0.73, y: bottom))
                context.stroke(dividers, with: .color(tint), style: stroke)
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

    private func applyDeviceOrientation(_ orientation: UIDeviceOrientation) {
        let target: RemoteLayoutOrientation
        switch orientation {
        case .landscapeLeft: target = .landscapeLeft
        case .landscapeRight: target = .landscapeRight
        case .portrait, .portraitUpsideDown: target = .portrait
        default:
            return
        }
        guard target != layoutOrientation else { return }
        withAnimation(ZTransferMotion.standard) {
            layoutOrientation = target
        }
    }

    private func cycleLayoutOrientation() {
        withAnimation(ZTransferMotion.standard) {
            switch layoutOrientation {
            case .portrait: layoutOrientation = .landscapeLeft
            case .landscapeLeft: layoutOrientation = .landscapeRight
            case .landscapeRight: layoutOrientation = .portrait
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
