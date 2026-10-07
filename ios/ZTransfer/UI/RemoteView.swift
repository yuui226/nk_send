import SwiftUI
import UIKit

private enum RemoteLayoutOrientation: Int, Equatable {
    case portrait = 0
    case landscapeLeft = 1
    case landscapeRight = 2

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
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var entitlements = PremiumEntitlementStore.shared
    private let onStopped: ((Bool) async -> Void)?
    private let onPreparing: (() async -> Void)?
    private let onTransportLost: (() -> Void)?
    private let isSessionConnected: Bool
    private let onRetrySTA: () -> Void
    private let isUSBSession: Bool
    private let toolDefaults: UserDefaults
    private let wirelessMode: WirelessMode?
    @StateObject private var model: RemoteViewModel
    @State private var gridMenuPresented = false
    @State private var gridMenuClosing = false
    @State private var editingTools = false
    @State private var selectedField: RemoteExposureField?
    // RemoteToolPreferences persists these values immediately on mutation.
    @StateObject private var tools: RemoteToolPreferences
    @StateObject private var lutMonitor: RemoteLUTMonitorState
    @State private var lutFolderPickerPresented = false
    @State private var lutListPresented = false
    @State private var dispMode: RemoteDispMode = .camera
    @State private var histogramMode: RemoteHistogramMode = .off
    // The developer entry is deliberately scoped to this RemoteView instance.
    // Four consecutive FPS taps (each gap < 1.5 s) reveal it; four toggles also
    // leave the FPS overlay in its original state.
    @State private var developerUnlocked = false
    @State private var fpsTapCount = 0
    @State private var lastFpsTapAt: TimeInterval = 0
    @State private var developerPanelPresented = false
    @State private var developerLogLines: [String] = []
    @State private var signalExpanded = false
    @State private var exposureMode: RemoteExposureAssist = .off
    @State private var batteryExpanded = false
    @State private var layoutOrientation: RemoteLayoutOrientation = .portrait
    @State private var immersiveFullscreen = false
    @State private var orientationCandidate: RemoteLayoutOrientation?
    @State private var manuallySuppressedOrientation: RemoteLayoutOrientation?
    @State private var orientationStabilityTask: Task<Void, Never>?
    @State private var rotationTransitionTask: Task<Void, Never>?
    @State private var switchingRotation = false
    @State private var rotationOpacity = 1.0
    @State private var orientationNotificationsActive = false
    @State private var stopCleanupStarted = false

    private var effectiveDesqueeze: Double {
        RemoteDisplayOptions.normalizedDesqueeze(tools.desqueeze)
    }

    init(session: CameraSession?, presentationMode: CameraPresentationMode? = nil, recordingDirectory: URL? = nil,
         isSessionConnected: Bool = true, toolDefaults: UserDefaults = .standard,
         remoteCamera: (any RemoteCameraControlling)? = nil,
         onRetrySTA: @escaping () -> Void = {}, onPreparing: (() async -> Void)? = nil,
         onStopped: ((Bool) async -> Void)? = nil,
         onTransportLost: (() -> Void)? = nil) {
        let preferences = RemoteToolPreferences(defaults: toolDefaults)
        self.toolDefaults = toolDefaults
        _tools = StateObject(wrappedValue: preferences)
        _lutMonitor = StateObject(wrappedValue: RemoteLUTMonitorState(preferences: RemoteLUTPreferences(defaults: toolDefaults)))
        _dispMode = State(initialValue: preferences.disp)
        _histogramMode = State(initialValue: preferences.histogram)
        _exposureMode = State(initialValue: preferences.exposure)
        _layoutOrientation = State(initialValue: preferences.locked
                                  ? (RemoteLayoutOrientation(rawValue: preferences.lockedRotation) ?? .portrait) : .portrait)
        self.onStopped = onStopped
        self.onPreparing = onPreparing
        self.onTransportLost = onTransportLost
        self.isSessionConnected = isSessionConnected && (session != nil || remoteCamera != nil)
        self.onRetrySTA = onRetrySTA
        let mode = session.map { CameraPresentationMode(isUSB: $0.isUSB, wirelessMode: $0.wirelessMode) }
            ?? presentationMode ?? .sta
        self.isUSBSession = mode == .usb
        self.wirelessMode = mode == .sta ? .sta : .ap
        let camera: any RemoteCameraControlling = remoteCamera ?? session.map { $0 as any RemoteCameraControlling }
            ?? DisconnectedRemoteCamera(isUSB: mode == .usb)
        _model = StateObject(wrappedValue: RemoteViewModel(camera: camera,
                                                            recordingDirectory: recordingDirectory,
                                                            onTransportLost: onTransportLost))
    }

    var body: some View {
        ZStack {
            ZTransferColors.background.ignoresSafeArea()
            GeometryReader { proxy in
                if immersiveFullscreen {
                    cameraToolOverlay(immersiveRemoteLayout, landscape: true)
                        .frame(width: proxy.size.height, height: proxy.size.width)
                        .rotationEffect(.degrees(layoutOrientation.rotationDegrees))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else if layoutOrientation.isLandscape {
                    cameraToolOverlay(landscapeRemoteLayout, landscape: true)
                        // Android keeps the host portrait and rotates a measured
                        // landscape canvas inside it, so system bars stay put.
                        .frame(width: proxy.size.height, height: proxy.size.width)
                        .rotationEffect(.degrees(layoutOrientation.rotationDegrees))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .transition(.opacity)
                } else {
                    cameraToolOverlay(portraitRemoteLayout, landscape: false)
                        .transition(.opacity)
                }
            }
            .opacity(rotationOpacity)

            if developerPanelPresented {
                developerPanel
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .fileImporter(isPresented: $lutFolderPickerPresented, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let access = RemoteLUTFolderAccess(defaults: toolDefaults)
            do { try access.save(url); lutMonitor.beginScan(url); lutMonitor.scanned(try access.scan(), acquiredFolder: url) }
            catch { lutMonitor.scanFailed((error as? RemoteLUTFolderAccessError) == .denied ? .denied : .read) }
        }
        .sheet(isPresented: $lutListPresented) {
            NavigationStack {
                List {
                    Section("LUT") {
                        Button("选择文件夹") { lutListPresented = false; lutFolderPickerPresented = true }
                        ForEach(lutMonitor.files, id: \.identifier) { file in
                            Button {
                                lutListPresented = false
                                let access = RemoteLUTFolderAccess(defaults: toolDefaults)
                                guard let generation = lutMonitor.beginSelection(file) else { return }
                                Task {
                                    do {
                                        let table = try CubeLUTParser.parse(access.read(file))
                                        await MainActor.run { lutMonitor.loaded(file, lut: table, generation: generation); lutMonitor.presented(generation: generation) }
                                    } catch {
                                        await MainActor.run { lutMonitor.failed(generation: generation, reason: "read") }
                                    }
                                }
                            } label: {
                                HStack { Text(file.relativePath); Spacer(); if lutMonitor.active?.file.identifier == file.identifier { Image(systemName: "checkmark") } }
                            }
                        }
                    }
                }
                .navigationTitle("LUT")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .overlay(alignment: .top) {
            if !immersiveFullscreen, !developerPanelPresented,
               let hint = model.interactionHint ?? model.recordingHint ?? model.localRecordingHint ?? lutMonitor.failure {
                Text(hint)
                    .font(.system(size: 14, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(ZTransferColors.primaryText)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .padding(.horizontal, 20)
                    .padding(.top, 60)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top))
                            .animation(.easeInOut(duration: 0.20)),
                        removal: .opacity.animation(.easeOut(duration: 0.30))
                    ))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            RemoteTrialBadge(meter: model.usageMeter)
                .padding(.trailing, 12)
                .padding(.bottom, 8)
                .allowsHitTesting(false)
        }
        .overlay {
            if model.movieMode && model.state.capture == .recording {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(red: 1, green: 0.259, blue: 0.302), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: model.trialEnded) { ended in
            guard ended else { return }
            RemoteTrialNotice.pending = true
            dismiss()
        }
        .onChange(of: scenePhase) { phase in
            model.usageMeter.setActive(phase == .active)
        }
        .animation(.easeInOut(duration: 0.20), value: model.interactionHint)
        .animation(.easeInOut(duration: 0.20), value: model.recordingHint)
        .animation(.easeInOut(duration: 0.20), value: model.localRecordingHint)
        .animation(ZTransferMotion.standard, value: layoutOrientation)
        .statusBarHidden(false)
        .task {
            await onPreparing?()
            guard !Task.isCancelled, !stopCleanupStarted, isSessionConnected else { return }
            model.setLocalRecordingToolVisible(tools.layout(movie: model.movieMode).visible(.record), fixedRecorder: layoutOrientation.isLandscape)
            model.setHDLiveView(tools.hd)
            model.start()
            model.setLevelVisible(tools.level)
        }
        // Orientation is intentionally scoped to the monitor page. The rest
        // of the app stays portrait; this page rotates its own canvas to match
        // the device instead of changing the application's interface size.
        .onAppear {
            let normalizedDesqueeze = effectiveDesqueeze
            if tools.desqueeze != normalizedDesqueeze { tools.desqueeze = normalizedDesqueeze }
            model.setExposureMeterVisible(tools.meter)
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
            orientationStabilityTask?.cancel()
            rotationTransitionTask?.cancel()
            Task { @MainActor in
                await model.stopAndWait()
                await onStopped?(model.transportLossWasNotified)
            }
        }
        .onChange(of: model.movieMode) { _ in
            gridMenuPresented = false
            model.setLocalRecordingToolVisible(tools.layout(movie: model.movieMode).visible(.record), fixedRecorder: layoutOrientation.isLandscape)
        }
        .onChange(of: layoutOrientation) { _ in
            gridMenuPresented = false
            model.dismissCameraTool()
            model.setLocalRecordingToolVisible(tools.layout(movie: model.movieMode).visible(.record), fixedRecorder: layoutOrientation.isLandscape)
        }
        .onChange(of: tools.locked) { _ in
            orientationStabilityTask?.cancel()
            orientationCandidate = nil
        }
        .onChange(of: tools.hd) { model.setHDLiveView($0) }
        .onChange(of: tools.level) { model.setLevelVisible($0) }
        .onChange(of: tools.meter) { model.setExposureMeterVisible($0) }
        .onChange(of: model.levelVisible) { visible in
            // Unsupported level queries disable the preference; page teardown
            // only clears live state and must not erase the saved selection.
            if !stopCleanupStarted { tools.level = visible }
        }
        .onChange(of: histogramMode) { _ in
            model.setFrameAnalysis(histogram: histogramMode != .off, zebra: exposureMode == .zebra, waveform: tools.waveform, falseColor: exposureMode == .falseColor, histogramRGB: histogramMode == .rgb)
        }
        .onChange(of: exposureMode) { _ in
            model.setFrameAnalysis(histogram: histogramMode != .off, zebra: exposureMode == .zebra, waveform: tools.waveform, falseColor: exposureMode == .falseColor, histogramRGB: histogramMode == .rgb)
        }
        .onChange(of: tools.waveform) { _ in
            model.setFrameAnalysis(histogram: histogramMode != .off, zebra: exposureMode == .zebra, waveform: tools.waveform, falseColor: exposureMode == .falseColor, histogramRGB: histogramMode == .rgb)
        }
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

            adaptiveRemoteToolbar
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

                    adaptiveRemoteToolbar
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

    private var immersiveRemoteLayout: some View {
        ZStack(alignment: .topTrailing) {
            remoteViewfinder
                .padding(6)
            // Android keeps the original top-right return button mounted in
            // immersive mode. Only its action changes; no second fullscreen-
            // specific chevron is drawn over the viewfinder.
            remoteBackButton
            .padding(12)
        }
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
        Button {
            if gridMenuPresented {
                gridMenuClosing = true
            } else if let panel = model.cameraToolPanel {
                panel.requestClose()
            } else if editingTools {
                setEditingTools(false)
            } else if immersiveFullscreen {
                withAnimation(ZTransferMotion.standard) { immersiveFullscreen = false }
            } else {
                dismiss()
            }
        } label: {
            Image(systemName: "arrow.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(ZTransferColors.primaryText)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 22))
        .accessibilityLabel(AppLocalized.resource(
            immersiveFullscreen ? "cd_remote_fullscreen_exit" : "cd_back"
        ))
        .accessibilityIdentifier("remote-monitor-back")
    }

    private var remoteSignalButton: some View {
        Button {
            if isUSBSession {
                guard isSessionConnected else { return }
                withAnimation(signalExpanded
                              ? .timingCurve(0.4, 0, 0.2, 1, duration: 0.22)
                              : .spring(response: 0.42, dampingFraction: 0.72)) {
                    signalExpanded.toggle()
                }
            } else if wirelessMode == .sta && !isSessionConnected {
                onRetrySTA()
            } else if !isSessionConnected {
                CameraWirelessSettings.open(.ap)
            }
        } label: {
            HStack(spacing: signalExpanded ? 5 : 0) {
                PhotoListSignalIcon(isUSB: isUSBSession, wirelessMode: wirelessMode,
                                    connected: isSessionConnected)
                if signalExpanded && isUSBSession && isSessionConnected {
                    Text(AppLocalized.resource("connection_usb"))
                        .zTransferTypography(.labelSmall, weight: .medium)
                        .foregroundStyle(ZTransferColors.accentBlue)
                }
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 40, minHeight: 36, maxHeight: 36)
        }
        .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 22))
        .modifier(DisconnectedSignalBreath(connected: isSessionConnected))
        .accessibilityLabel(AppLocalized.resource(
            isUSBSession ? "connection_usb" :
                (wirelessMode == .sta && !isSessionConnected
                    ? "sta_signal_disconnected_reconnect" : "sta_signal_connected")
        ))
    }

    private var remoteBatteryButton: some View {
        let valueText = model.batteryPercent.map { "\($0)%" } ?? "--"
        let tint = remoteBatteryTint(model.batteryPercent)
        return Button {
            withAnimation(batteryExpanded
                          ? .timingCurve(0.4, 0, 0.2, 1, duration: 0.22)
                          : .spring(response: 0.42, dampingFraction: 0.72)) {
                batteryExpanded.toggle()
            }
        } label: {
            HStack(spacing: batteryExpanded ? 6 : 0) {
                RemoteBatteryIcon(percent: model.batteryPercent, tint: tint)
                .frame(width: 21, height: 15)
                if batteryExpanded {
                    Text(valueText)
                        .font(.system(size: 12, weight: .medium, design: .default))
                        .foregroundStyle(tint)
                        .fixedSize()
                        .transition(.opacity)
                }
            }
            .frame(width: batteryExpanded ? 54 : 21, height: 15, alignment: .leading)
            .frame(width: batteryExpanded ? 82 : 48, height: 36)
        }
        .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 22))
        .accessibilityLabel("\(AppLocalized.resource("cd_camera_battery")) \(valueText)")
    }

    private func remoteBatteryTint(_ percent: Int?) -> Color {
        guard let percent else { return ZTransferColors.secondaryText }
        if percent <= 20 { return ZTransferColors.statusError }
        if percent <= 50 { return ZTransferColors.accentOrange }
        return ZTransferColors.statusConnected
    }

    private var adaptiveRemoteToolbar: some View {
        RemoteToolModeCrossfade(movie: model.movieMode) { displayedMovie in
            configuredRemoteToolbar(movie: displayedMovie)
        }
    }

    private func configuredRemoteToolbar(movie displayedMovie: Bool) -> some View {
        RemoteConfiguredToolbar(layout: tools.layout(movie: displayedMovie),
                                editing: editingTools,
                                isActive: displayedMovie == model.movieMode,
                                controls: remoteToolControls(movie: displayedMovie),
                                leading: Group {
            if developerUnlocked && !editingTools {
                remoteToolButton(active: false,
                                 accessibilityLabel: AppLocalized.resource("cd_dev_panel"),
                                 label: {
                    Image(systemName: "ladybug.fill")
                        .font(.system(size: 16, weight: .semibold))
                }) {
                    gridMenuPresented = false
                    model.dismissCameraTool()
                    withAnimation(ZTransferMotion.standard) { developerPanelPresented = true }
                }
            }
        }, trailing: remoteFixedToolControls, pinnedEndCount: 2, fixedRecorder: layoutOrientation.isLandscape,
                                applyHidden: { hidden in
            for tool in hidden { setToolVisible(tool, false) }
        })
    }

    private var remoteFixedToolControls: [RemoteFixedToolControl] {
        var controls: [RemoteFixedToolControl] = []
        if !layoutOrientation.isLandscape {
            controls.append(RemoteFixedToolControl(id: "manage", view: AnyView(
                remoteToolButton(active: false, accessibilityLabel: AppLocalized.resource(editingTools ? "remote_tool_done" : "remote_tool_manage"), label: {
                    RemoteEditorIcon(kind: editingTools ? .check : .settings).frame(width: 19, height: 19)
                }) { setEditingTools(!editingTools) }
                .accessibilityIdentifier("remote-tools-manage")
            )))
        }
        controls.append(RemoteFixedToolControl(id: "fullscreen", view: AnyView(
            remoteToolButton(active: false, accessibilityLabel: AppLocalized.resource("cd_remote_fullscreen_enter"), label: { RemoteFullscreenIcon().frame(width: 17, height: 17) }) {
                enterImmersiveFullscreen()
            }.disabled(editingTools || tools.locked)
        )))
        controls.append(RemoteFixedToolControl(id: "rotate", view: AnyView(
            remoteToolButton(active: layoutOrientation.isLandscape, accessibilityLabel: AppLocalized.resource("cd_remote_rotate"), label: { RemoteRotateIcon().frame(width: 20, height: 20) }) {
                cycleLayoutOrientation()
            }.disabled(editingTools || tools.locked)
                .accessibilityIdentifier("remote-tool-rotate")
        )))
        controls.append(RemoteFixedToolControl(id: "disp", view: AnyView(
            remoteToolButton(active: dispMode != .camera,
                             accessibilityLabel: "DISP",
                             label: { Text("DISP").font(.system(size: 8, weight: .bold)) }) {
                dispMode = dispMode.next
                tools.disp = dispMode
            }
        )))
        return controls
    }

    // Each entry owns its existing production action; layout order and
    // visibility are independent of this renderer registry.
    private func remoteToolControls(movie: Bool) -> [RemoteTool: AnyView] {
        [
            .hd: AnyView(configuredRemoteToolButton(.hd, movie: movie, active: model.hdLiveView, accessibilityLabel: AppLocalized.resource("dev_hd_liveview"), label: { Text("HD").font(.system(size: 13, weight: .bold)).fixedSize() }) {
                withAnimation(ZTransferMotion.standard) { tools.hd.toggle() }
            }),
            .fps: AnyView(configuredRemoteToolButton(.fps, movie: movie, active: tools.fps, accessibilityLabel: AppLocalized.resource("dev_fps_overlay"), label: { Text("FPS").font(.system(size: 10.5, weight: .bold)).fixedSize() }) {
                registerFpsTap()
            }),
            .histogram: AnyView(configuredRemoteToolButton(.histogram, movie: movie, active: histogramMode != .off, accessibilityLabel: AppLocalized.resource("cd_remote_histogram"), label: { RemoteHistogramIcon().frame(width: 19, height: 19) }) {
                withAnimation(ZTransferMotion.standard) {
                    histogramMode = switch histogramMode {
                    case .off: .rgb
                    case .rgb: .luma
                    case .luma: .off
                    }
                    tools.histogram = histogramMode
                }
            }),
            .waveform: AnyView(configuredRemoteToolButton(.waveform, movie: movie, active: tools.waveform != .off, accessibilityLabel: AppLocalized.resource("remote_tool_waveform"), label: {
                Text("W").font(.system(size: 12, weight: .bold)).frame(width: 19, height: 19)
            }) {
                tools.waveform = switch tools.waveform {
                case .off: .rgb
                case .rgb: .luma
                case .luma: .off
                }
            }),
            .grid: AnyView(configuredRemoteToolButton(.grid, movie: movie, active: tools.grid != .off, accessibilityLabel: AppLocalized.resource("remote_tool_grid"), label: { RemoteFramingGridMark(grid: tools.grid).frame(width: 19, height: 19) }) {
                model.dismissCameraTool()
                selectedField = nil
                developerPanelPresented = false
                if gridMenuPresented { gridMenuClosing = true }
                else { gridMenuClosing = false; gridMenuPresented = true }
            }.geniePopupAnchor(.remoteGrid)),
            .exposure: AnyView(configuredRemoteToolButton(.exposure, movie: movie, active: exposureMode != .off, accessibilityLabel: AppLocalized.resource("cd_remote_zebra"), label: { RemoteZebraIcon().frame(width: 18, height: 18) }) {
                withAnimation(ZTransferMotion.standard) {
                    exposureMode = switch exposureMode {
                    case .off: .zebra
                    case .zebra: .falseColor
                    case .falseColor: .off
                    }
                    tools.exposure = exposureMode
                }
            }),
            .meter: AnyView(configuredRemoteToolButton(.meter, movie: movie, active: tools.meter, accessibilityLabel: AppLocalized.resource("remote_tool_meter"), label: {
                Text("EV").font(.system(size: 9, weight: .bold)).frame(width: 19, height: 19)
            }) {
                tools.meter.toggle()
            }),
            .lut: AnyView(configuredRemoteToolButton(.lut, movie: movie, active: lutMonitor.active != nil, accessibilityLabel: "LUT", label: {
                Text("LUT").font(.system(size: 8, weight: .bold)).frame(width: 21, height: 19)
            }) {
                if lutMonitor.files.isEmpty { lutFolderPickerPresented = true } else { lutListPresented = true }
            }),
            .desqueeze: AnyView(configuredRemoteToolButton(.desqueeze, movie: movie, active: effectiveDesqueeze > 1.001,
                             accessibilityLabel: "\(RemoteDisplayOptions.label(for: effectiveDesqueeze))×",
                             label: {
                if effectiveDesqueeze > 1.001 {
                    Text(RemoteDisplayOptions.label(for: effectiveDesqueeze))
                        .font(.system(size: 12, weight: .bold))
                        .fixedSize()
                } else {
                    RemoteAspectIcon().frame(width: 18, height: 18)
                }
            }) {
                withAnimation(ZTransferMotion.standard) {
                    tools.desqueeze = RemoteDisplayOptions.nextDesqueeze(after: effectiveDesqueeze)
                }
            }),
            .level: AnyView(configuredRemoteToolButton(.level, movie: movie, active: model.levelVisible, accessibilityLabel: AppLocalized.resource("cd_remote_level"), label: { RemoteLevelIcon().frame(width: 18, height: 18) }) {
                withAnimation(ZTransferMotion.standard) {
                    tools.level.toggle()
                }
            }),
            .audio: AnyView(configuredRemoteToolButton(.audio, movie: movie, active: tools.audio, accessibilityLabel: AppLocalized.resource("cd_remote_audio_levels"), label: { RemoteAudioIcon().frame(width: 18, height: 18) }) {
                withAnimation(ZTransferMotion.standard) { tools.audio.toggle() }
            }),
            .whiteBalance: AnyView(cameraToolButton(.whiteBalance, movie: movie)),
            .focusArea: AnyView(cameraToolButton(.focusArea, movie: movie)),
            .lock: AnyView(configuredRemoteToolButton(.lock, movie: movie, active: tools.locked,
                accessibilityLabel: AppLocalized.resource("remote_tool_lock"), label: {
                    RemoteEditorIcon(kind: tools.locked ? .lock : .lockOpen).frame(width: 19, height: 19)
                }) { setRotationLocked(!tools.locked, showHint: true) }),
            .record: AnyView(Group {
                if editingTools {
                    remoteToolEditButton(.record, movie: movie) {
                        RemoteEditorIcon(kind: .videocam).frame(width: 19, height: 19)
                    }
                } else { remoteRecordButton }
            })
        ]
    }

    private func cameraToolOverlay<Content: View>(_ content: Content, landscape: Bool) -> some View {
        content.overlayPreferenceValue(GeniePopupAnchorPreferenceKey.self) { anchors in
            GeometryReader { proxy in
                if gridMenuPresented {
                    RemoteGridMenu(tools: tools, anchor: anchors[.remoteGrid].map { proxy[$0] },
                        hostSize: proxy.size, landscape: landscape, closing: $gridMenuClosing,
                        dismiss: { gridMenuPresented = false })
                }
                if let panel = model.cameraToolPanel {
                    let trigger: GeniePopupTrigger = panel.tool == .whiteBalance ? .remoteWhiteBalance : .remoteFocusArea
                    RemoteCameraToolMenuHost(panel: panel, anchor: anchors[trigger].map { proxy[$0] },
                        hostSize: proxy.size, landscape: landscape, canWrite: model.cameraToolWritesAllowed)
                        .id(panel.id)
                }
            }
        }
    }

    private func cameraToolButton(_ tool: RemoteCameraTool, movie: Bool) -> some View {
        let layoutTool: RemoteTool = tool == .whiteBalance ? .whiteBalance : .focusArea
        return configuredRemoteToolButton(layoutTool, movie: movie, active: false,
            accessibilityLabel: AppLocalized.resource(layoutTool.titleKey), label: {
                if let panel = model.cameraToolPanel, !editingTools {
                    RemoteCameraToolMark(panel: panel, tool: tool)
                } else { RemoteCameraToolStaticMark(tool: tool) }
            }) {
                selectedField = nil
                developerPanelPresented = false
                gridMenuPresented = false
                model.openCameraTool(tool)
            }
            .geniePopupAnchor(tool == .whiteBalance ? .remoteWhiteBalance : .remoteFocusArea)
    }

    private func setEditingTools(_ editing: Bool) {
        orientationStabilityTask?.cancel()
        orientationCandidate = nil
        selectedField = nil
        model.dismissCameraTool()
        developerPanelPresented = false
        gridMenuPresented = false
        editingTools = editing && !layoutOrientation.isLandscape
    }

    @ViewBuilder
    private func configuredRemoteToolButton<Label: View>(_ tool: RemoteTool, movie: Bool, active: Bool,
        accessibilityLabel: String, @ViewBuilder label: @escaping () -> Label, action: @escaping () -> Void) -> some View {
        if editingTools {
            remoteToolEditButton(tool, movie: movie, label: label)
        } else {
            remoteToolButton(active: active, accessibilityLabel: AppLocalized.resource(tool.titleKey), label: label, action: action)
        }
    }

    private func remoteToolEditButton<Label: View>(_ tool: RemoteTool, movie: Bool,
        @ViewBuilder label: @escaping () -> Label) -> some View {
        let layout = tools.layout(movie: movie)
        return RemoteToolVisibilityContent(layout: layout, tool: tool) { visible in
            remoteToolButton(active: visible, accessibilityLabel: AppLocalized.resource(tool.titleKey), label: {
                RemoteToolAnimatedMark(content: label)
            }) { setToolVisible(tool, !layout.visible(tool)) }
            .overlay(alignment: .topTrailing) {
                RemoteEditorIcon(kind: visible ? .visible : .hidden)
                    .fill(ZTransferColors.primaryText)
                    .padding(1)
                    .frame(width: 14, height: 14)
                    .background(ZTransferColors.surface, in: Circle())
                    .offset(x: 2, y: -2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .accessibilityValue(AppLocalized.resource(visible ? "remote_tool_show" : "remote_tool_hide"))
            .accessibilityActions {
                if visible {
                    Button(AppLocalized.resource("remote_tool_move_up")) {
                        layout.move(tool, to: (layout.shownTools.firstIndex(of: tool) ?? 0) - 1)
                    }
                    Button(AppLocalized.resource("remote_tool_move_down")) {
                        layout.move(tool, to: (layout.shownTools.firstIndex(of: tool) ?? 0) + 1)
                    }
                }
            }
        }
    }

    private func setRotationLocked(_ locked: Bool, showHint: Bool) {
        orientationStabilityTask?.cancel()
        orientationCandidate = nil
        if locked { tools.lockedRotation = layoutOrientation.rawValue }
        tools.locked = locked
        if showHint { model.showRotationLockHint(locked) }
    }

    private func setToolVisible(_ tool: RemoteTool, _ visible: Bool) {
        if !visible {
            switch tool {
            case .whiteBalance: if model.cameraToolPanel?.tool == .whiteBalance { model.dismissCameraTool() }
            case .focusArea: if model.cameraToolPanel?.tool == .focusArea { model.dismissCameraTool() }
            case .record: model.setLocalRecordingToolVisible(false, fixedRecorder: false)
            case .hd: model.setHDLiveView(false)
            case .lock: setRotationLocked(false, showHint: false)
            case .histogram:
                histogramMode = .off
                tools.histogram = .off
            case .grid: tools.grid = .off; gridMenuPresented = false
            case .exposure:
                exposureMode = .off
                tools.exposure = .off
            default: break
            }
        }
        tools.layout(movie: model.movieMode).setVisible(tool, visible)
        if tool == .record {
            model.setLocalRecordingToolVisible(visible, fixedRecorder: layoutOrientation.isLandscape)
        }
    }

    private func registerFpsTap() {
        withAnimation(ZTransferMotion.standard) { tools.fps.toggle() }
        let now = ProcessInfo.processInfo.systemUptime
        fpsTapCount = now - lastFpsTapAt < 1.5 ? fpsTapCount + 1 : 1
        lastFpsTapAt = now
        if fpsTapCount >= 4 { developerUnlocked = true }
    }

    /// The Android panel also hosts an experimental full camera-capability
    /// probe. Product direction keeps only the hidden entry and log window on
    /// iOS; no probing commands or temporary camera-property writes originate here.
    private var developerPanel: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(ZTransferMotion.standard) { developerPanelPresented = false }
                    }

                VStack(spacing: 8) {
                    HStack {
                        Text(AppLocalized.resource("dev_panel_title"))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(ZTransferColors.primaryText)
                        Spacer()
                        developerPanelButton(systemName: "doc.on.doc",
                                             accessibilityLabel: AppLocalized.resource("lab_copy_log")) {
                            UIPasteboard.general.string = developerLogLines.joined(separator: "\n")
                        }
                        developerPanelButton(systemName: "xmark",
                                             accessibilityLabel: AppLocalized.resource("cd_close")) {
                            withAnimation(ZTransferMotion.standard) { developerPanelPresented = false }
                        }
                    }

                    ScrollViewReader { reader in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(developerLogLines.enumerated()), id: \.offset) { index, line in
                                    Text(line)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(line.hasPrefix("!!")
                                                         ? ZTransferColors.accentOrange
                                                         : Color.white.opacity(0.76))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(index)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                        }
                        .frame(height: 170)
                        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                        .onChange(of: developerLogLines.count) { count in
                            guard count > 0 else { return }
                            reader.scrollTo(count - 1, anchor: .bottom)
                        }
                    }
                }
                .padding(14)
                .padding(.bottom, proxy.safeAreaInsets.bottom)
                .background {
                    ZTransferGlassSurface(cornerRadius: 20, kind: .panel)
                }
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
                .shadow(color: .black.opacity(0.18), radius: 6, y: -1)
                .contentShape(Rectangle())
                .onTapGesture { }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
    }

    private func developerPanelButton(systemName: String, accessibilityLabel: String,
                                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ZTransferColors.secondaryText)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 16))
        .accessibilityLabel(accessibilityLabel)
    }

    private var remoteRecordButton: some View {
        let phase = model.localRecordingPhase
        let recording = phase == .recording || phase == .paused
        let expanded = recording || phase == .finalizing
        let saved = phase == .saved
        return ZStack(alignment: .leading) {
            ZTransferGlassSurface(cornerRadius: 18, kind: .panel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button {
                switch phase {
                case .idle: model.startLocalRecording()
                case .recording, .paused: model.stopLocalRecording()
                case .finalizing, .saved: break
                }
            } label: {
                ZStack {
                    Circle().fill(Color.white.opacity(0.001))
                    if saved {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(ZTransferColors.statusConnected)
                    } else if recording || phase == .finalizing {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(ZTransferColors.statusError)
                            .frame(width: 12, height: 12)
                    } else {
                        Circle().fill(ZTransferColors.statusError).frame(width: 14, height: 14)
                    }
                }
                .frame(width: 28, height: 28)
            }
            .buttonStyle(ZTransferGlassButtonStyle(
                cornerRadius: 14,
                active: saved,
                activeColor: ZTransferColors.statusConnected
            ))
            .disabled(phase == .finalizing || saved)
            .opacity(!expanded && !saved && !entitlements.access.isPro ? 0.45 : 1)
            .padding(.leading, 4)

            if expanded {
                Button { model.toggleLocalRecordingPause() } label: {
                    Image(systemName: phase == .paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(ZTransferColors.primaryText)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 14))
                .disabled(phase == .finalizing)
                .offset(x: 38)
                .transition(.opacity.combined(with: .scale(scale: 0.7)))
            } else if saved {
                Text(AppLocalized.resource("remote_rec_saved_label"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ZTransferColors.statusConnected)
                    .offset(x: 34)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }

            if recording {
                Text(String(format: "%d:%02d", model.localRecordingSeconds / 60,
                            model.localRecordingSeconds % 60))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.62), in: Capsule())
                    .offset(x: 8, y: -28)
            }
        }
        .frame(width: saved ? 88 : (expanded ? 70 : 36), height: 36, alignment: .leading)
        .animation(ZTransferMotion.emphasized, value: phase)
        .accessibilityElement(children: .contain)
    }

    private func remoteToolButton<Label: View>(
        active: Bool,
        accessibilityLabel: String,
        @ViewBuilder label: @escaping () -> Label,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            label()
                .foregroundStyle(active ? ZTransferColors.accentBlue : ZTransferColors.secondaryText)
                .environment(\.remoteToolTint, active ? ZTransferColors.accentBlue : ZTransferColors.secondaryText)
                .frame(minWidth: 20, minHeight: 20)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(ZTransferGlassButtonStyle(
            cornerRadius: 18,
            active: active,
            activeColor: ZTransferColors.accentBlue
        ))
        .accessibilityLabel(accessibilityLabel)
    }

    private var shutterButton: some View {
        RemoteShutterButton(
            capture: model.state.capture,
            movieMode: model.movieMode,
            enabled: model.state.session == .ready && !model.recordingBusy,
            onQuickTap: { if model.movieMode { model.toggleRecording() } else { model.capture() } },
            onFocusStart: { model.beginHalfPress() },
            onRelease: { model.endHalfPress(fire: $0) }
        )
    }

    private var remoteViewfinder: some View {
        GeometryReader { proxy in
            let image = model.frameImage
            let aspect = (image.map { $0.size.width / max($0.size.height, 1) } ?? 1.5) * CGFloat(effectiveDesqueeze)
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(RadialGradient(
                        colors: [Color(white: 0.38), Color(white: 0.18)],
                        center: .center,
                        startRadius: 12,
                        endRadius: 420
                    ))
                if let image {
                    RemoteZoomableViewfinder(aspect: aspect, imageSize: image.size, metadata: model.frameMetadata, onFocus: {
                        model.focus(at: $0, coordinateSize: image.size)
                    }) {
                        ZStack {
                            if let activeLUT = lutMonitor.active?.lut, let cgImage = image.cgImage {
                                RemoteLUTMetalView(image: cgImage, lut: activeLUT)
                                    .aspectRatio(aspect, contentMode: .fit)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                RemoteViewfinderImage(image: image, aspect: aspect,
                                    multiplier: CGFloat(effectiveDesqueeze), size: proxy.size)
                            }
                            if exposureMode == .falseColor,
                               let pixels = model.frameFalseColorPixels,
                               model.frameFalseColorSize.width > 0 {
                                RemoteFalseColorOverlay(pixels: pixels,
                                    width: Int(model.frameFalseColorSize.width),
                                    height: Int(model.frameFalseColorSize.height), aspect: aspect)
                            }
                            if tools.grid != .off {
                                RemoteFramingGridOverlay(grid: tools.grid, aspect: aspect)
                            }
                            if exposureMode == .zebra, let zebraMask = model.frameZebraMask {
                                IOSZebraOverlay(mask: zebraMask, aspect: aspect)
                            }
                            if let point = model.state.focus.point, model.state.focus.phase != .idle {
                                RemoteFocusReticle(phase: model.state.focus.phase, point: point,
                                    nonce: model.state.focus.nonce, aspect: aspect)
                            }
                            if let marker = model.confirmedFocusMarker {
                                let metadata = model.frameMetadata
                                let cameraFrame = model.frameReceivedAtUptime >= marker.confirmedAtUptime &&
                                    (marker.subjectTracking || metadata?.focusJudgement == .focused)
                                    ? metadata?.selectedFocusFrame : nil
                                IOSConfirmedFocusReticle(
                                    marker: marker,
                                    cameraFrame: cameraFrame,
                                    visible: model.state.focus.phase == .idle &&
                                        !model.halfPressVisualActive &&
                                        (!marker.subjectTracking || model.state.focus.tracking),
                                    aspect: aspect
                                )
                                .id(marker.nonce)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    if exposureMode == .falseColor {
                        RemoteFalseColorLegend()
                            .padding(.top, 22)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .allowsHitTesting(false)
                    }
                    if tools.meter, let ev = model.exposureMeterEV {
                        Text(String(format: "%+.1f EV", ev))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.62), in: Capsule())
                            .padding(10)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .allowsHitTesting(false)
                    }
                    if histogramMode != .off {
                        RemoteHistogramOverlay(bins: model.frameHistogram ?? [], rgb: histogramMode == .rgb ? model.frameHistogramRGB : nil)
                            .frame(width: 150, height: 72)
                            .padding(12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                    if tools.waveform != .off, let waveform = model.frameWaveform {
                        RemoteWaveformOverlay(channels: waveform)
                            .frame(width: 150, height: 72)
                            .padding(12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                    if model.levelVisible, let roll = model.levelRoll {
                        RemoteHorizonOverlay(roll: Float(roll), pitch: model.levelPitch.map(Float.init))
                            .allowsHitTesting(false)
                    }
                    if model.movieMode, tools.audio,
                       let levels = model.frameMetadata?.soundLevels {
                        IOSSoundMeter(levels: levels)
                            .frame(width: 32, height: 116)
                            .padding(.leading, 10)
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: .bottomLeading)
                            .allowsHitTesting(false)
                    }
                } else if tools.grid != .off {
                    RemoteFramingGridOverlay(grid: tools.grid, aspect: aspect)
                        .allowsHitTesting(false)
                }
                if tools.fps, model.state.fps > 0 {
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
                if model.state.capture == .recording {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(ZTransferColors.statusError)
                            .frame(width: 7, height: 7)
                        Text(String(format: "%d:%02d", model.recordingSeconds / 60,
                                    model.recordingSeconds % 60))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(10)
                    .allowsHitTesting(false)
                }
                if model.state.liveViewStable {
                    HStack(spacing: 4) {
                        if let program = model.exposureProgram {
                            RemoteStatusBadge(text: RemoteExposureParameters.format(program.property, raw: program.current), weight: .bold)
                        }
                        if let focusMode = model.focusModeDescriptor {
                            RemoteStatusBadge(text: RemoteExposureParameters.format(focusMode.property, raw: focusMode.current), weight: .semibold)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(10)
                    .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                if !isSessionConnected {
                    Text(AppLocalized.resource("camera_not_connected"))
                        .zTransferTypography(.bodySmall)
                        .foregroundStyle(.white.opacity(0.78))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .aspectRatio(remoteViewfinderAspect, contentMode: .fit)
    }

    private var remoteViewfinderAspect: CGFloat {
        guard let image = model.frameImage else { return 1.5 * CGFloat(effectiveDesqueeze) }
        return (image.size.width / max(image.size.height, 1)) * CGFloat(effectiveDesqueeze)
    }

    private struct RemoteBatteryIcon: View {
        let percent: Int?
        let tint: Color

        private var level: Int {
            guard let percent, percent > 0 else { return 0 }
            if percent <= 33 { return 1 }
            if percent <= 66 { return 2 }
            return 3
        }

        var body: some View {
            Canvas { context, size in
                let body = CGRect(x: 0.5, y: 0.5, width: 17.5, height: size.height - 1)
                context.stroke(Path(roundedRect: body, cornerRadius: 2.5),
                               with: .color(tint), lineWidth: 1)
                let gap: CGFloat = 1
                let inset: CGFloat = 2
                let barWidth = (body.width - inset * 2 - gap * 2) / 3
                for index in 0..<3 {
                    let rect = CGRect(x: body.minX + inset + CGFloat(index) * (barWidth + gap),
                                      y: body.minY + inset,
                                      width: barWidth,
                                      height: body.height - inset * 2)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1),
                                 with: .color(index < level ? tint : tint.opacity(0.28)))
                }
                context.fill(Path(roundedRect: CGRect(x: body.maxX, y: size.height * 0.30,
                                                       width: 3, height: size.height * 0.40),
                                  cornerRadius: 1),
                             with: .color(tint))
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

    private func applyDeviceOrientation(_ orientation: UIDeviceOrientation) {
        guard !editingTools, !tools.locked else { return }
        let target: RemoteLayoutOrientation
        switch orientation {
        case .landscapeLeft: target = .landscapeLeft
        case .landscapeRight: target = .landscapeRight
        case .portrait: target = .portrait
        default:
            return
        }
        guard target != orientationCandidate else { return }
        orientationCandidate = target
        orientationStabilityTask?.cancel()
        guard target != manuallySuppressedOrientation else { return }
        manuallySuppressedOrientation = nil
        orientationStabilityTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled, orientationCandidate == target else { return }
            requestLayoutOrientation(target)
        }
    }

    private func cycleLayoutOrientation() {
        guard !switchingRotation, !editingTools, !tools.locked else { return }
        manuallySuppressedOrientation = orientationCandidate
        orientationStabilityTask?.cancel()
        let target: RemoteLayoutOrientation = switch layoutOrientation {
        case .portrait: .landscapeLeft
        case .landscapeLeft: .landscapeRight
        case .landscapeRight: .portrait
        }
        requestLayoutOrientation(target)
    }

    private func enterImmersiveFullscreen() {
        if layoutOrientation == .portrait { cycleLayoutOrientation() }
        withAnimation(ZTransferMotion.standard) { immersiveFullscreen = true }
    }

    private func requestLayoutOrientation(_ target: RemoteLayoutOrientation) {
        guard target != layoutOrientation, !switchingRotation, !tools.locked, !editingTools else { return }
        switchingRotation = true
        rotationTransitionTask?.cancel()
        rotationTransitionTask = Task { @MainActor in
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.08)) { rotationOpacity = 0 }
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { switchingRotation = false; return }
            if !tools.locked && !editingTools { layoutOrientation = target }
            await Task.yield()
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.14)) { rotationOpacity = 1 }
            try? await Task.sleep(for: .milliseconds(140))
            switchingRotation = false
        }
    }

    private func fitImageRect(in size: CGSize, aspect: CGFloat) -> CGRect {
        guard aspect > 0, size.width > 0, size.height > 0 else { return .zero }
        let fitted = min(size.width / aspect, size.height)
        let width = fitted * aspect
        return CGRect(x: (size.width - width) / 2, y: (size.height - fitted) / 2,
                      width: width, height: fitted)
    }

    private var exposureGrid: some View {
        let fields: [RemoteExposureField] = [.exposureCompensation, .iso, .aperture, .shutter]
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(fields, id: \.self) { field in
                RemoteExposureTile(field: field, descriptor: model.exposureDescriptors[field],
                                   onOpenList: { gridMenuPresented = false; model.dismissCameraTool(); selectedField = field },
                                   onCommit: { model.setExposure(field, value: $0, feedback: false, immediate: false) },
                                   onDetent: { model.detentFeedback() },
                                   autoEnabled: field == .iso && model.autoISODescriptor != nil ? model.autoISOEnabled : nil,
                                   autoToggle: field == .iso && model.autoISODescriptor != nil ?
                                       { model.setAutoISO(!model.autoISOEnabled) } : nil,
                                   autoBusy: model.autoISOBusy,
                                   effectiveISO: model.effectiveISO?.current)
            }
        }
        .padding(.horizontal, 14)
    }
}

/// Two-stage shutter matching Android's 300 ms quick-tap/half-press split.
private struct RemoteShutterButton: View {
    let capture: RemoteCapturePhase
    let movieMode: Bool
    let enabled: Bool
    let onQuickTap: () -> Void
    let onFocusStart: () -> Void
    let onRelease: (Bool) -> Void
    @State private var pressed = false
    @State private var halfPressStarted = false
    @State private var timerTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Circle()
                .stroke(ZTransferColors.primaryText.opacity(enabled ? 0.88 : 0.30), lineWidth: 4)
                .frame(width: 82, height: 82)
            if capture == .capturing {
                ProgressView().controlSize(.large)
            } else {
                RoundedRectangle(cornerRadius: capture == .recording ? 8 : 41)
                    .fill(movieMode ? ZTransferColors.statusError : Color.white)
                    .frame(width: capture == .recording ? 30 : 64,
                           height: capture == .recording ? 30 : 64)
                    .scaleEffect(halfPressStarted ? 0.8 : 1)
                    .animation(ZTransferMotion.emphasized, value: capture)
            }
        }
        .frame(width: 82, height: 82)
        .scaleEffect(pressed ? 0.95 : 1)
        .animation(pressed ? .easeOut(duration: 0.1) : ZTransferMotion.emphasized, value: pressed)
        .contentShape(Circle())
        .gesture(dragGesture)
        .opacity(enabled ? 1 : 0.72)
        .accessibilityLabel(AppLocalized.resource("cd_remote_entry"))
        .onDisappear {
            timerTask?.cancel()
            timerTask = nil
            pressed = false
            halfPressStarted = false
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard enabled, !pressed else { return }
                pressed = true
                halfPressStarted = false
                timerTask?.cancel()
                timerTask = Task { @MainActor in
                    do { try await Task.sleep(nanoseconds: 300_000_000) }
                    catch { return }
                    guard pressed else { return }
                    halfPressStarted = true
                    onFocusStart()
                }
            }
            .onEnded { value in
                timerTask?.cancel()
                timerTask = nil
                pressed = false
                let inside = value.location.x >= 0 && value.location.x <= 82 &&
                    value.location.y >= 0 && value.location.y <= 82
                if halfPressStarted {
                    halfPressStarted = false
                    onRelease(inside)
                } else if inside {
                    onQuickTap()
                }
            }
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
    @State private var appearScale: CGFloat = 1.45

    var body: some View {
        GeometryReader { proxy in
            let fitted = min(proxy.size.width / max(aspect, 0.01), proxy.size.height)
            let rect = CGRect(x: (proxy.size.width - fitted * aspect) / 2,
                              y: (proxy.size.height - fitted) / 2,
                              width: fitted * aspect, height: fitted)
            let resultScale: CGFloat = phase == .focusing ? 1 : 0.9
            let scale = appearScale * resultScale
            let half = 32 * scale
            let requestedCenter = CGPoint(x: rect.minX + rect.width * CGFloat(point.x),
                                          y: rect.minY + rect.height * CGFloat(point.y))
            let center = CGPoint(
                x: rect.width >= half * 2
                    ? min(max(requestedCenter.x, rect.minX + half), rect.maxX - half)
                    : rect.midX,
                y: rect.height >= half * 2
                    ? min(max(requestedCenter.y, rect.minY + half), rect.maxY - half)
                    : rect.midY
            )
            let color: Color = switch phase {
            case .locked: ZTransferColors.statusConnected
            case .failed: ZTransferColors.statusError
            default: ZTransferColors.accentBlue
            }
            focusCornerPath(center: center, halfWidth: half, halfHeight: half,
                            cornerLength: 12 * scale)
                .stroke(color.opacity(0.95),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .animation(.spring(response: 0.42, dampingFraction: 0.72), value: phase)
                .onAppear {
                    appearScale = 1.45
                    withAnimation(.easeOut(duration: 0.18)) { appearScale = 1 }
                }
                .onChange(of: nonce) { _ in
                    appearScale = 1.45
                    withAnimation(.easeOut(duration: 0.18)) { appearScale = 1 }
                }
        }
        .allowsHitTesting(false)
    }
}

private func focusCornerPath(center: CGPoint, halfWidth: CGFloat, halfHeight: CGFloat,
                             cornerLength: CGFloat) -> Path {
    let left = center.x - halfWidth
    let right = center.x + halfWidth
    let top = center.y - halfHeight
    let bottom = center.y + halfHeight
    let horizontal = min(cornerLength, halfWidth)
    let vertical = min(cornerLength, halfHeight)
    return Path { path in
        path.move(to: CGPoint(x: left, y: top + vertical))
        path.addLine(to: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: left + horizontal, y: top))
        path.move(to: CGPoint(x: right - horizontal, y: top))
        path.addLine(to: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: right, y: top + vertical))
        path.move(to: CGPoint(x: left, y: bottom - vertical))
        path.addLine(to: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: left + horizontal, y: bottom))
        path.move(to: CGPoint(x: right - horizontal, y: bottom))
        path.addLine(to: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: right, y: bottom - vertical))
    }
}

private struct RemoteHistogramOverlay: View {
    let bins: [Int]
    let rgb: [[Int]]?
    var body: some View {
        Canvas { context, size in
            if let rgb, rgb.count == 3 {
                let peak = max(1, rgb.flatMap { $0 }.max() ?? 1)
                for channel in 0..<3 {
                    let color: Color = [.red, .green, .blue][channel]
                    var path = Path()
                    for index in 0..<min(256, rgb[channel].count) {
                        let x = size.width * CGFloat(index) / 256
                        let y = size.height * (1 - CGFloat(rgb[channel][index]) / CGFloat(peak))
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    context.stroke(path, with: .color(color.opacity(0.8)), lineWidth: 1)
                }
                return
            }
            guard !bins.isEmpty else { return }
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
}

private struct RemoteWaveformOverlay: View {
    let channels: [[Int]]
    var body: some View {
        Canvas { context, size in
            guard let first = channels.first, !first.isEmpty else { return }
            let peak = max(1, channels.flatMap { $0 }.max() ?? 1)
            let colors: [Color] = channels.count == 3 ? [.red, .green, .blue] : [.white]
            for (channel, bins) in channels.enumerated() {
                let color = colors[min(channel, colors.count - 1)]
                for row in 0..<RemoteExposureAnalysis.waveformHeight {
                    for column in 0..<RemoteExposureAnalysis.waveformWidth {
                        let count = bins[row * RemoteExposureAnalysis.waveformWidth + column]
                        guard count > 0 else { continue }
                        let alpha = Double(count) / Double(peak)
                        context.fill(Path(CGRect(
                            x: size.width * CGFloat(column) / 256,
                            y: size.height * CGFloat(row) / 128,
                            width: max(0.5, size.width / 256),
                            height: max(0.5, size.height / 128)
                        )), with: .color(color.opacity(alpha)))
                    }
                }
            }
        }
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
    }
}

private struct RemoteFalseColorOverlay: View {
    let pixels: [UInt32]
    let width: Int
    let height: Int
    let aspect: CGFloat

    var body: some View {
        GeometryReader { proxy in
            Image(decorative: makeImage(), scale: 1, orientation: .up)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
        }
        .aspectRatio(aspect, contentMode: .fit)
        .allowsHitTesting(false)
    }

    private func makeImage() -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<min(pixels.count, width * height) {
            let color = pixels[index]
            let offset = index * 4
            bytes[offset] = UInt8((color >> 16) & 255)
            bytes[offset + 1] = UInt8((color >> 8) & 255)
            bytes[offset + 2] = UInt8(color & 255)
            bytes[offset + 3] = 255
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }
}

private struct RemoteFalseColorLegend: View {
    private let labels = ["0", "5", "15", "40", "45", "55", "80", "95+"]
    private let colors: [Color] = [
        Color(red: 0x6B / 255, green: 0x39 / 255, blue: 0xB8 / 255),
        Color(red: 0x28 / 255, green: 0x74 / 255, blue: 0xD7 / 255),
        Color(red: 0x50 / 255, green: 0x55 / 255, blue: 0x5B / 255),
        Color(red: 0x5A / 255, green: 0xBE / 255, blue: 0x87 / 255),
        Color(red: 0xE7 / 255, green: 0x92 / 255, blue: 0xAE / 255),
        Color(red: 0xB9 / 255, green: 0xBD / 255, blue: 0xC2 / 255),
        Color(red: 0xF0 / 255, green: 0xD5 / 255, blue: 0x5D / 255),
        Color(red: 0xF1 / 255, green: 0x4D / 255, blue: 0x4D / 255)
    ]
    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                Text("Y′%")
                    .frame(width: 20)
                ForEach(labels, id: \.self) { Text($0).frame(width: 24.5) }
            }
            .font(.system(size: 7))
            .foregroundStyle(.white.opacity(0.8))
            HStack(spacing: 0) {
                ForEach(colors.indices, id: \.self) { index in
                    colors[index].frame(width: 24.5, height: 4)
                }
            }
            .padding(.leading, 20)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct IOSZebraOverlay: View {
    let mask: RemoteZebraMask
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

private struct IOSConfirmedFocusReticle: View {
    let marker: RemoteConfirmedFocusMarker
    let cameraFrame: RemoteLiveViewFocusFrame?
    let visible: Bool
    let aspect: CGFloat
    @State private var appearScale: CGFloat = 1.12
    @State private var cachedCameraFrame: RemoteLiveViewFocusFrame?

    var body: some View {
        GeometryReader { proxy in
            let fitted = min(proxy.size.width / max(aspect, 0.01), proxy.size.height)
            let imageWidth = fitted * aspect
            let imageRect = CGRect(x: (proxy.size.width - imageWidth) / 2,
                                   y: (proxy.size.height - fitted) / 2,
                                   width: imageWidth, height: fitted)
            let displayedFrame = cameraFrame ?? cachedCameraFrame
            let point = displayedFrame.map {
                RemoteFocusPoint(x: Double($0.centerX), y: Double($0.centerY))
            } ?? marker.fallbackPoint
            let visibilityScale: CGFloat = visible ? 1 : 0.82
            let rawHalfWidth = displayedFrame.map { imageRect.width * CGFloat($0.width) / 2 } ?? 25
            let rawHalfHeight = displayedFrame.map { imageRect.height * CGFloat($0.height) / 2 } ?? 25
            let halfWidth = min(max(rawHalfWidth * appearScale * visibilityScale,
                                    min(13, imageRect.width / 2)), imageRect.width / 2)
            let halfHeight = min(max(rawHalfHeight * appearScale * visibilityScale,
                                     min(13, imageRect.height / 2)), imageRect.height / 2)
            let requestedCenter = CGPoint(x: imageRect.minX + imageRect.width * CGFloat(point.x),
                                          y: imageRect.minY + imageRect.height * CGFloat(point.y))
            let center = CGPoint(
                x: imageRect.width >= halfWidth * 2
                    ? min(max(requestedCenter.x, imageRect.minX + halfWidth), imageRect.maxX - halfWidth)
                    : imageRect.midX,
                y: imageRect.height >= halfHeight * 2
                    ? min(max(requestedCenter.y, imageRect.minY + halfHeight), imageRect.maxY - halfHeight)
                    : imageRect.midY
            )
            focusCornerPath(center: center, halfWidth: halfWidth, halfHeight: halfHeight,
                            cornerLength: min(10, min(halfWidth, halfHeight)))
                .stroke(ZTransferColors.statusConnected.opacity(visible ? 0.85 : 0),
                        style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .animation(.easeInOut(duration: 0.20), value: visible)
                .onAppear {
                    cachedCameraFrame = cameraFrame
                    appearScale = 1.12
                    withAnimation(.easeOut(duration: 0.16)) { appearScale = 1 }
                }
                .onChange(of: cameraFrame) { next in
                    if let next { cachedCameraFrame = next }
                }
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
                    .fill(segment <= peak ? (segment >= 13 ? .red : segment >= 11 ? .yellow : .white.opacity(0.94)) : .white.opacity(0.14))
                    .frame(width: 7, height: 5)
                    .opacity(segment <= current ? 1 : 0.68)
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

/// The one-second countdown only invalidates this badge, not the video layout.
private struct RemoteTrialBadge: View {
    @ObservedObject var meter: RemoteUsageMeter
    var body: some View {
        if !meter.isPro {
            Text(AppLocalized.formattedResource("remote_trial_left", [
                "%1$s": String(format: "%d:%02d", meter.secondsLeft / 60, meter.secondsLeft % 60)
            ]))
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(ZTransferColors.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background { ZTransferGlassSurface(cornerRadius: 9, kind: .panel) }
        }
    }
}
