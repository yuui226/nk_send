import SwiftUI
import Combine
import UIKit

/// The diagnostic text can change for every displayed focus frame. Observe
/// it only while drawing this panel; the monitor owner does not subscribe.
struct RemoteDiagnosticReportReader<Content: View>: View {
    @ObservedObject var output: RemoteDiagnosticReport
    @ViewBuilder let content: (String) -> Content
    var body: some View { content(output.text) }
}

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

private struct RemoteToolIconAnchor: ViewModifier {
    let tool: RemoteTool
    private var trigger: GeniePopupTrigger? {
        switch tool {
        case .grid: .remoteGrid
        case .pictureControl: .remotePictureControl
        case .lut: .remoteLUT
        case .whiteBalance: .remoteWhiteBalance
        case .focusArea: .remoteFocusArea
        case .focusMode: .remoteFocusMode
        default: nil
        }
    }
    @ViewBuilder func body(content: Content) -> some View {
        if let trigger { content.geniePopupAnchor(trigger) }
        else { content }
    }
}

/// One lazy owner for one monitor presentation. The children retain independent
/// state, preferences and cleanup; forwarding only their existing notifications
/// preserves the page's observation boundaries without rebuilding throwaway
/// camera/review models whenever the parent list refreshes.
@MainActor
final class RemoteViewLifetime: @preconcurrency ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    let model: RemoteViewModel
    let tools: RemoteToolPreferences
    let folders: PictureControlFolderLifetime
    let lut: RemoteLUTMonitorLifetime
    let review: RemotePhotoReviewLifetime
    private var observations: [AnyCancellable] = []

    init(camera: any RemoteCameraControlling, session: CameraSession?, tools: RemoteToolPreferences,
         defaults: UserDefaults, entitlements: PremiumEntitlementStore, freeUsage: FreeUsageStore,
         onTransportLost: (() -> Void)?) {
        #if DEBUG
        ButtonInteractionTrace.recordNow("monitor-owner-created")
        #endif
        self.tools = tools
        folders = PictureControlFolderLifetime(defaults: defaults)
        lut = RemoteLUTMonitorLifetime(RemoteLUTMonitorState(preferences: RemoteLUTPreferences(defaults: defaults),
                                                           access: RemoteLUTFolderAccess(defaults: defaults)))
        let model = RemoteViewModel(camera: camera, onTransportLost: onTransportLost,
                                    entitlements: entitlements, freeUsage: freeUsage)
        self.model = model
        review = RemotePhotoReviewLifetime(RemotePhotoReviewModel(frames: model.reviewFrames,
            openCatalog: {
                guard let session else { throw CancellationError() }
                return try await session.openRemoteReviewCatalog()
            }, endLiveView: { await camera.endLiveView() },
            restartLiveView: { model.restartAfterPhotoReview() },
            isConnected: { !model.transportLossWasNotified },
            onActiveChanged: { model.setPhotoReviewActive($0) }))
        observations = [model.objectWillChange, tools.objectWillChange, folders.objectWillChange,
                        lut.objectWillChange, review.objectWillChange].map { changes in
            changes.sink { [weak self] in self?.objectWillChange.send() }
        }
    }
}

/// Native monitor surface. Transport and frame lifecycle live in
/// `RemoteViewModel`; this view only renders the camera frame and the controls
/// that are already present in Android's RemoteScreen.
struct RemoteView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var entitlements: PremiumEntitlementStore
    private let onStopped: ((Bool) async -> Void)?
    private let onPreparing: (() async -> Void)?
    private let onTransportLost: (() -> Void)?
    private let isSessionConnected: Bool
    private let onRetrySTA: () -> Void
    private let isUSBSession: Bool
    private let toolDefaults: UserDefaults
    private let wirelessMode: WirelessMode?
    private let reviewSession: CameraSession?
    private let reviewQueue: TransferQueueViewModel?
    @StateObject private var lifetime: RemoteViewLifetime
    private var reviewLifetime: RemotePhotoReviewLifetime { lifetime.review }
    private var review: RemotePhotoReviewModel { reviewLifetime.review }
    private var model: RemoteViewModel { lifetime.model }
    private var pictureControlFolders: PictureControlFolderLifetime { lifetime.folders }
    @State private var pictureControlPanel: PictureControlPanelModel?
    @State private var pictureControlReport = ""
    @State private var pictureControlPresented = false
    @State private var pictureControlPicker = PictureControlFolderPickerState()
    @State private var gridMenuPresented = false
    @State private var gridMenuClosing = false
    @State private var editingTools = false
    @State private var selectedField: RemoteExposureField?
    // RemoteToolPreferences persists these values immediately on mutation.
    private var tools: RemoteToolPreferences { lifetime.tools }
    private var lutLifetime: RemoteLUTMonitorLifetime { lifetime.lut }
    private var lutMonitor: RemoteLUTMonitorState { lutLifetime.monitor }
    @State private var lutFolderPickerPresented = false
    @State private var lutListPresented = false
    @State private var lutMenuClosing = false
    @State private var lutPickedFolder: URL?
    @State private var dispMode: RemoteDispMode = .camera
    @State private var histogramMode: RemoteHistogramMode = .off
    // The developer entry is deliberately scoped to this RemoteView instance.
    // Four consecutive FPS taps (each gap < 1.5 s) reveal it; four toggles also
    // leave the FPS overlay in its original state.
    @State private var developerUnlocked = false
    @State private var fpsTapCount = 0
    @State private var lastFpsTapAt: TimeInterval = 0
    @State private var developerPanelPresented = false
    @State private var monitorHintAnimator = RemoteMonitorHintAnimator()
    @State private var developerLogLines: [String] = []
    @State private var developerReportCache = RemoteDeveloperReportCache()
    private let persistedFocusDiagnosticReport: String
    @State private var exposureMode: RemoteExposureAssist = .off
    @State private var batteryExpanded = false
    @State private var monitorHelpPresented = false
    @AppStorage private var monitorHelpViewed: Bool
    @State private var layoutOrientation: RemoteLayoutOrientation = .portrait
    @State private var orientationSession = RemoteOrientationSession<RemoteLayoutOrientation>()
    @State private var orientationStabilityTask: Task<Void, Never>?
    @State private var switchingRotation = false
    @State private var orientationNotificationsActive = false
    @State private var stopCleanupStarted = false

    private var effectiveDesqueeze: Double {
        RemoteDisplayOptions.normalizedDesqueeze(tools.desqueeze)
    }

    private var monitorStorageStatusText: String? {
        let entries = monitorStorageStatusItems
        guard !entries.isEmpty else { return nil }
        return entries.joined(separator: "   ·   ")
    }

    private var monitorStorageStatusItems: [String] {
        let entries = model.monitorStorageFreeBytes.sorted { $0.key < $1.key }
        guard !entries.isEmpty else { return [] }
        func capacityLabel(_ bytes: Int64) -> String {
            String(format: "%.1f GB", locale: Locale.current,
                   Double(bytes) / 1_000_000_000.0)
        }
        return entries.enumerated().map { index, entry in
            guard model.monitorStorageSlotCount > 1 else { return capacityLabel(entry.value) }
            let slot = model.monitorStorageSlotByID[entry.key] ?? (index + 1)
            return AppLocalized.formattedResource("monitor_disp_card", [
                "%1$d": "\(slot)",
                "%2$s": capacityLabel(entry.value)
            ])
        }
    }

    private var monitorFocusModeText: String? {
        guard let descriptor = model.focusModeDescriptor else { return nil }
        if RemoteFocusMode.manual(property: descriptor.property, value: descriptor.current) { return "MF" }
        return RemoteFocusMode.label(property: descriptor.property, value: descriptor.current)
            ?? RemoteExposureParameters.format(descriptor.property, raw: descriptor.current)
    }

    private var monitorModeText: String? {
        guard let descriptor = model.exposureProgram else { return nil }
        return RemoteExposureParameters.format(descriptor.property, raw: descriptor.current)
    }

    private let onClose: (() -> Void)?
    private func closeMonitor() { if let onClose { onClose() } else { dismiss() } }

    init(session: CameraSession?, queueModel: TransferQueueViewModel? = nil, presentationMode: CameraPresentationMode? = nil,
         isSessionConnected: Bool = true, toolDefaults: UserDefaults = .standard,
         remoteCamera: (any RemoteCameraControlling)? = nil, freeUsage: FreeUsageStore = .shared,
         entitlements: PremiumEntitlementStore = .shared,
         onClose: (() -> Void)? = nil,
         onRetrySTA: @escaping () -> Void = {}, onPreparing: (() async -> Void)? = nil,
         onStopped: ((Bool) async -> Void)? = nil,
         onTransportLost: (() -> Void)? = nil) {
        #if DEBUG
        ButtonInteractionTrace.recordNow("monitor-init-start")
        defer { ButtonInteractionTrace.recordNow("monitor-init-end") }
        #endif
        let preferences = RemoteToolPreferences(defaults: toolDefaults)
        self.onClose = onClose
        self.toolDefaults = toolDefaults
        _monitorHelpViewed = AppStorage(wrappedValue: false, "monitor_help_viewed", store: toolDefaults)
        _entitlements = ObservedObject(wrappedValue: entitlements)
        _dispMode = State(initialValue: preferences.disp)
        _histogramMode = State(initialValue: preferences.histogram)
        _exposureMode = State(initialValue: preferences.exposure)
        persistedFocusDiagnosticReport = toolDefaults.string(forKey: "focus_report_v1") ?? ""
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
        _lifetime = StateObject(wrappedValue: RemoteViewLifetime(camera: camera, session: session,
            tools: preferences, defaults: toolDefaults, entitlements: entitlements, freeUsage: freeUsage,
            onTransportLost: onTransportLost))
        reviewSession = session
        reviewQueue = queueModel

    }

    var body: some View {
        #if DEBUG
        ButtonInteractionTrace.recordNow("monitor-body-start")
        defer { ButtonInteractionTrace.recordNow("monitor-body-end") }
        #endif
        return ZStack {
            ZTransferColors.background.ignoresSafeArea()
            RemoteRotationSurface(rotation: layoutOrientation.rotationDegrees, onSettled: finishLayoutRotation) {
                monitorCanvas
            }
        }
        .overlay {
            if reviewLifetime.active, let reviewSession, let reviewQueue {
                RemoteReviewSurface(rotation: layoutOrientation.rawValue) { landscape, insets in
                    RemotePhotoReviewView(model: review, session: reviewSession, queue: reviewQueue,
                                          connected: isSessionConnected, landscape: landscape,
                                          contentInsets: insets)
                }
            }
        }
        .fileImporter(isPresented: $pictureControlPicker.active, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): pictureControlPicker.complete(folder: urls.first)
            case .failure(let error):
                pictureControlPicker.complete(folder: nil)
                if (error as NSError).code != NSUserCancelledError { model.pictureControlNotice(AppLocalized.resource("lut_folder_denied")) }
            }
        }
        .onChange(of: pictureControlPicker.didReturn) { if $0 { finishPictureControlFolderPicker() } }
        .fileImporter(isPresented: $lutFolderPickerPresented, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): lutPickedFolder = urls.first
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    model.showMonitorHint(AppLocalized.resource("lut_folder_denied"), source: .lut)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !layoutOrientation.isLandscape {
                RemoteTrialBadge(meter: model.usageMeter)
                    .padding(.trailing, 16)
                    .padding(.bottom, 12)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: model.trialEnded) { ended in
            guard ended else { return }
            RemoteTrialNotice.pending = true
            closeMonitor()
        }
        .onChange(of: scenePhase) { phase in
            model.usageMeter.setActive(phase == .active)
            model.setExposureMeterForeground(phase == .active)
            if phase != .active {
                lutMonitor.suspendRendering()
                pauseOrientationCandidate()
            } else {
                finishPictureControlFolderPicker()
                refreshOrientationCandidate()
            }
        }
        .onChange(of: model.monitorHint.visible) { monitorHintAnimator.setVisible($0) }
        .animation(ZTransferMotion.standard, value: layoutOrientation)
        .statusBarHidden(false)
        .task {
            #if DEBUG
            ButtonInteractionTrace.recordNow("monitor-prepare-start")
            #endif
            model.preferredComputerControl = tools.computerControl
            model.onComputerControlPreferenceChanged = { [weak tools] enabled in
                tools?.computerControl = enabled
            }
            await onPreparing?()
            #if DEBUG
            ButtonInteractionTrace.recordNow("monitor-prepare-end")
            #endif
            guard !Task.isCancelled, !stopCleanupStarted, isSessionConnected else { return }
            model.setHDLiveView(tools.hd)
            model.setMovieFormatMonitoring(dispMode.showsCameraInformation)
            model.setStorageMonitoring(dispMode.showsCameraInformation)
            model.setDisplayDetailsMonitoring(dispMode.showsCameraInformation)
            configureFrameAnalysis()
            model.setExposureMeterForeground(scenePhase == .active)
            model.setExposureMeterVisible(tools.meter)
            model.start()
            model.setLevelVisible(tools.level)
        }
        .task(id: lutEnvironment) {
            guard !stopCleanupStarted else { return }
            let environment = lutEnvironment
            lutMonitor.environment(movie: environment.movie, available: environment.available,
                                   visible: environment.visible)
            if environment.foreground, !lutFolderPickerPresented, let picked = lutPickedFolder {
                lutPickedFolder = nil
                lutMonitor.refreshFolder(replacing: picked)
            }
        }
        .task(id: model.focusDiagnosticRunning) {
            guard model.focusDiagnosticRunning else { return }
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled, model.focusDiagnosticRunning else { return }
            model.stopFocusDiagnostic(reason: "60s")
        }
        // Orientation is intentionally scoped to the monitor page. The rest
        // of the app stays portrait; this page rotates its own canvas to match
        // the device instead of changing the application's interface size.
        .onAppear {
            #if DEBUG
            ButtonInteractionTrace.recordNow("monitor-appeared")
            #endif
            monitorHintAnimator.setVisible(model.monitorHint.visible)
            lutMonitor.onNotice = { [weak model] key in
                model?.showMonitorHint(AppLocalized.resource(key), source: .lut)
            }
            lutMonitor.onCommit = {
                if exposureMode == .falseColor { exposureMode = .off; tools.exposure = .off }
            }
            lutMonitor.onCloseMenu = { lutMenuClosing = true }
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
            closePictureControl()
            pictureControlFolders.folders.close()
            monitorHintAnimator.stop()
            lutMonitor.close()
            lutMonitor.onNotice = nil
            lutMonitor.onCommit = nil
            lutMonitor.onCloseMenu = nil
            guard !stopCleanupStarted else { return }
            stopCleanupStarted = true
            model.markMonitorHintHostInactive()
            if orientationNotificationsActive {
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
                orientationNotificationsActive = false
            }
            orientationStabilityTask?.cancel()
            Task { @MainActor in
                await review.close()
                await model.stopAndWait()
                await onStopped?(model.transportLossWasNotified)
            }
        }
        .onChange(of: model.movieMode) { _ in
            closePictureControl()
            if model.movieMode && review.active { Task { await review.close() } }
            gridMenuPresented = false
        }
        .onChange(of: isSessionConnected) { connected in
            if !connected { closePictureControl() }
            if !connected && review.active { Task { await review.close() } }
        }
        .onChange(of: editingTools) { _ in closePictureControl(); dismissLUTMenu(); monitorHelpPresented = false }
        .onChange(of: layoutOrientation) { _ in closePictureControl(); dismissLUTMenu(); monitorHelpPresented = false }
        .onChange(of: selectedField) { if $0 != nil { closePictureControl(); dismissLUTMenu() } }
        .onChange(of: developerPanelPresented) { if $0 { closePictureControl(); dismissLUTMenu() } }
        .onChange(of: gridMenuPresented) { if $0 { closePictureControl(); dismissLUTMenu() } }
        .onChange(of: model.cameraToolPanel?.id) { if $0 != nil { closePictureControl(); dismissLUTMenu() } }
        .onChange(of: pictureControlPresented) { if $0 { dismissLUTMenu() } }
        .onChange(of: lutListPresented) { if $0 { closePictureControl() } }
        .onChange(of: dispMode) { mode in
            model.setMovieFormatMonitoring(mode.showsCameraInformation)
            model.setStorageMonitoring(mode.showsCameraInformation)
            model.setDisplayDetailsMonitoring(mode.showsCameraInformation)
        }
        .onReceive(model.focusDiagnosticOutput.$text.dropFirst()) { report in
            guard !report.isEmpty else { return }
            toolDefaults.set(report, forKey: "focus_report_v1")
        }
        .onChange(of: model.videoDiagnosticLog) { log in
            guard !log.isEmpty else { return }
            developerLogLines.append(contentsOf: log.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        }
        .onChange(of: model.computerControlLog) { log in
            if !log.isEmpty { developerLogLines.append(log) }
        }
        .onChange(of: layoutOrientation) { _ in
            gridMenuPresented = false
            model.dismissCameraTool()
        }
        .onChange(of: tools.locked) { locked in
            pauseOrientationCandidate()
            orientationSession.discardPending()
            if !locked { refreshOrientationCandidate() }
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
            configureFrameAnalysis()
        }
        .onChange(of: exposureMode) { mode in
            if mode == .falseColor { lutMonitor.turnOff() }
            configureFrameAnalysis()
        }
        .onChange(of: tools.waveform) { _ in
            configureFrameAnalysis()
        }
    }

    private var monitorCanvas: some View {
        GeometryReader { proxy in
            if layoutOrientation.isLandscape {
                cameraToolOverlay(landscapeRemoteLayout, landscape: true)
                    // Keep the host portrait and rotate its local canvas;
                    // system bars and the full-screen review stay physical.
                    .frame(width: proxy.size.height, height: proxy.size.width)
                    .rotationEffect(.degrees(layoutOrientation.rotationDegrees))
                    .frame(width: proxy.size.width, height: proxy.size.height)
            } else {
                cameraToolOverlay(portraitRemoteLayout, landscape: false)
            }
        }
        .overlayPreferenceValue(TipPopupAnchorPreferenceKey.self) { anchors in
            TipPopupLayer(isPresented: monitorHelpPresented && !layoutOrientation.isLandscape && !reviewLifetime.active) {
                if let anchor = anchors[.monitor] {
                    Color.clear.contentShape(Rectangle()).onTapGesture { monitorHelpPresented = false }
                        .gesture(DragGesture(minimumDistance: 10).onChanged { _ in })
                    TipGuideBubble(anchor: anchor, titleKey: "monitor_help_title", sections: TipGuides.monitor,
                        alignLeading: true, tools: tools, close: { monitorHelpPresented = false })
                }
            }
        }
    }

    private struct LUTEnvironment: Hashable {
        let movie: Bool
        let available: Bool
        let visible: Bool
        let foreground: Bool
        let pickedFolder: URL?
    }

    private var lutEnvironment: LUTEnvironment {
        LUTEnvironment(movie: model.movieMode,
            available: isSessionConnected && model.initialLoaded && model.frameImage != nil &&
                scenePhase == .active && !lutFolderPickerPresented && !stopCleanupStarted,
            visible: tools.layout(movie: model.movieMode).visible(.lut),
            foreground: scenePhase == .active, pickedFolder: lutPickedFolder)
    }

    private func configureFrameAnalysis() {
        model.setFrameAnalysis(histogram: histogramMode != .off, zebra: exposureMode == .zebra, waveform: tools.waveform, falseColor: exposureMode == .falseColor, histogramRGB: histogramMode == .rgb)
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

            HStack(spacing: 0) {
                ZStack { reviewButton(large: true) }.frame(maxWidth: .infinity).frame(height: 56)
                shutterButton
                Color.clear.frame(maxWidth: .infinity).frame(height: 56)
            }
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var landscapeRemoteLayout: some View {
        GeometryReader { proxy in
            let layout = RemoteLandscapeLayout(width: proxy.size.width, height: proxy.size.height,
                                                imageAspect: remoteViewfinderAspect, photoReview: model.reviewVisible)
            ZStack(alignment: .topLeading) {
                remoteViewfinder
                    .frame(width: layout.image.width, height: layout.image.height)
                    .offset(x: layout.image.minX, y: layout.image.minY)
                RemoteLandscapeControls(layout: layout, toolLayout: tools.layout(movie: model.movieMode),
                    control: { remoteToolControl($0, movie: model.movieMode) }, onPanelChange: closeMonitorPanels,
                    onTick: { ZTransferHaptics.shared.play(.navigation) }, applyHidden: { hidden in
                        for tool in hidden { setToolVisible(tool, false) }
                    }, rotate: AnyView(remoteRotateButton), back: AnyView(remoteBackButton),
                    disp: AnyView(remoteDispButton), shutter: { AnyView(remoteShutter(diameter: $0)) },
                    review: { AnyView(reviewButton(large: false, sizeScale: $0)) }, parameter: { index, height in
                        AnyView(exposureTile(exposureFields[index], height: height))
                    })
                    .frame(width: layout.controls.width, height: layout.controls.height)
                    .offset(x: layout.controls.minX, y: layout.controls.minY)
                RemoteMonitorHintAnchor(horizontalInset: 12)
                    .frame(width: layout.image.width)
                    .offset(x: layout.image.minX, y: layout.image.minY + layout.image.height * 0.20)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .overlay(alignment: .bottomTrailing) {
                RemoteTrialBadge(meter: model.usageMeter, compact: true)
                    .padding(.trailing, 6).padding(.bottom, 4)
                    .allowsHitTesting(false)
            }
        }
    }

    private func openPictureControl() {
        if pictureControlPresented { pictureControlPanel?.requestClose(); return }
        closeMonitorPanels()
        // Android permits browsing while camera controls are initializing; only
        // mutations use canWrite. A missing/unreadable camera reports the same
        // opening failure instead of silently swallowing the tool tap.
        let session = reviewSession
        let movie = model.movieMode
        let current: @Sendable () async -> Bool = { [weak model] in
            await MainActor.run { model.map { $0.movieMode == movie } ?? false }
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("picture_control_backups", isDirectory: true)
        let panel = PictureControlPanelModel(folders: pictureControlFolders.folders,
            current: { model.movieMode == movie },
            allowed: { model.pictureControlWritesAllowed },
            busy: { model.setPictureControlWriting($0) },
            readOverview: { log in
                guard let session else { throw PTPSessionError.invalidResponse }
                return try await session.readPictureControlOverview(movie: movie, backupDirectory: directory, isCurrent: current, log: log)
            },
            change: { slot, change, log in
                guard let session else { throw PTPSessionError.invalidResponse }
                try await session.changePictureControl(slot: slot, change: change, movie: movie,
                    backupDirectory: directory, isCurrent: current, log: log)
            }, closesFolders: false, reports: pictureControlFolders.reports)
        panel.notice = { model.pictureControlNotice($0) }
        panel.movie = movie
        panel.onReport = { pictureControlReport = $0 }
        panel.feedback = { ZTransferHaptics.shared.play(.action) }
        panel.interactionAllowed = scenePhase == .active
        panel.dismiss = { [weak panel] in
            guard let panel, pictureControlPanel === panel else { return }
            closePictureControl()
        }
        pictureControlPanel = panel; pictureControlPresented = true
        panel.open()
    }

    private func choosePictureControlFolder(_ slot: Int) {
        pictureControlPicker.begin(slot: slot)
        pictureControlPanel?.interactionAllowed = false
    }

    private func finishPictureControlFolderPicker() {
        guard let returned = pictureControlPicker.consume(resumed: scenePhase == .active) else { return }
        if let folder = returned.folder { pictureControlFolders.folders.changeFolder(folder) }
        guard tools.layout(movie: model.movieMode).visible(.pictureControl) else { return }
        if !pictureControlPresented { openPictureControl() }
        pictureControlPanel?.editingSlot = returned.slot
        pictureControlPanel?.interactionAllowed = true
    }

    private func closePictureControl() {
        pictureControlPanel?.close()
        pictureControlPanel = nil
        pictureControlPresented = false
    }

    private func closeMonitorPanels() {
        closePictureControl()
        gridMenuPresented = false
        gridMenuClosing = false
        model.dismissCameraTool()
        dismissLUTMenu()
        selectedField = nil
        developerPanelPresented = false
    }

    private func dismissLUTMenu() {
        lutMonitor.dismissMenu()
        lutListPresented = false
        lutMenuClosing = false
    }

    private var remoteTopBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                remoteSignalButton
                remoteBatteryButton
                TipLightbulbButton(attention: !monitorHelpViewed, size: 36,
                    accessibilityLabel: AppLocalized.resource("monitor_help_title")) {
                    guard !layoutOrientation.isLandscape else { return }
                    monitorHelpViewed = true
                    monitorHelpPresented = true
                }.tipPopupAnchor(.monitor)
            }
            RemoteMonitorHintAnchor(horizontalInset: 6).frame(maxWidth: .infinity)
            remoteBackButton
        }
    }

    private var remoteBackButton: some View {
        Button {
            if monitorHelpPresented {
                monitorHelpPresented = false
            } else if pictureControlPresented {
                pictureControlPanel?.requestClose()
            } else if gridMenuPresented {
                gridMenuClosing = true
            } else if let panel = model.cameraToolPanel {
                panel.requestClose()
            } else if editingTools {
                setEditingTools(false)
            } else {
                closeMonitor()
            }
        } label: {
            Image(systemName: "arrow.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(ZTransferColors.primaryText)
                .frame(width: 40, height: 36)
        }
        .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 22))
        .accessibilityLabel(AppLocalized.resource("cd_back"))
        .accessibilityIdentifier("remote-monitor-back")
    }

    private var remoteSignalButton: some View {
        CameraSignalControl(isUSB: isUSBSession, wirelessMode: wirelessMode,
                            connected: isSessionConnected)
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
        AndroidBooleanCrossfade(selected: model.movieMode) { displayedMovie in
            configuredRemoteToolbar(movie: displayedMovie)
        }
    }

    private func configuredRemoteToolbar(movie displayedMovie: Bool) -> some View {
        RemoteConfiguredToolbar(layout: tools.layout(movie: displayedMovie),
                                editing: editingTools,
                                isActive: displayedMovie == model.movieMode,
                                control: { remoteToolControl($0, movie: displayedMovie) },
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
        }, trailing: remoteFixedToolControls, pinnedEndCount: 2,
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
        controls.append(RemoteFixedToolControl(id: "lock", view: AnyView(remoteLockButton(movie: model.movieMode))))
        controls.append(RemoteFixedToolControl(id: "rotate", view: AnyView(remoteRotateButton)))
        return controls
    }

    private var remoteRotateButton: some View {
        remoteToolButton(active: false, enabled: !editingTools && !tools.locked, fixed: true,
                         accessibilityLabel: AppLocalized.resource("remote_tool_rotate"),
                         label: { toolMark(.rotate) }) {
            cycleLayoutOrientation()
        }.accessibilityIdentifier("remote-tool-rotate")
    }

    private func remoteLockButton(movie: Bool) -> some View {
        configuredRemoteToolButton(.lock, movie: movie, active: tools.locked,
            accessibilityLabel: AppLocalized.resource("remote_tool_lock"), label: { toolMark(.lock) }) {
                setRotationLocked(!tools.locked, showHint: true)
            }
    }

    private var remoteDispButton: some View {
        remoteToolButton(active: false, accessibilityLabel: "DISP",
                         label: { Text("DISP").font(.system(size: 8)) }) {
            dispMode = dispMode.next
            tools.disp = dispMode
        }.accessibilityIdentifier("remote-tool-disp")
    }

    // Android RemoteToolBar/LandscapeMonitorControls invoke a renderer only
    // for displayed tools. Preserve every action, but do not eagerly construct
    // hidden tools, duplicate pinned tools, or an unopened landscape dock.
    private func remoteToolControl(_ tool: RemoteTool, movie: Bool) -> AnyView {
        switch tool {
        case .hd: return AnyView(configuredRemoteToolButton(.hd, movie: movie, active: model.hdLiveView, accessibilityLabel: AppLocalized.resource("dev_hd_liveview"), label: { toolMark(.hd) }) {
                withAnimation(ZTransferMotion.standard) { tools.hd.toggle() }
            })
        case .fps: return AnyView(configuredRemoteToolButton(.fps, movie: movie, active: tools.fps, accessibilityLabel: AppLocalized.resource("dev_fps_overlay"), label: { toolMark(.fps) }) {
                registerFpsTap()
            })
        case .histogram: return AnyView(configuredRemoteToolButton(.histogram, movie: movie, active: histogramMode != .off, accessibilityLabel: AppLocalized.resource("cd_remote_histogram"), label: { toolMark(.histogram) }) {
                withAnimation(ZTransferMotion.standard) {
                    histogramMode = switch histogramMode {
                    case .off: .rgb
                    case .rgb: .luma
                    case .luma: .off
                    }
                    tools.histogram = histogramMode
                }
            })
        case .waveform: return AnyView(configuredRemoteToolButton(.waveform, movie: movie, active: tools.waveform != .off, accessibilityLabel: AppLocalized.resource("remote_tool_waveform"), label: {
                toolMark(.waveform)
            }) {
                tools.waveform = switch tools.waveform {
                case .off: .rgb
                case .rgb: .luma
                case .luma: .off
                }
            })
        case .grid: return AnyView(configuredRemoteToolButton(.grid, movie: movie, active: tools.grid != .off, accessibilityLabel: AppLocalized.resource("remote_tool_grid"), label: { toolMark(.grid) }) {
                model.dismissCameraTool()
                selectedField = nil
                developerPanelPresented = false
                if gridMenuPresented { gridMenuClosing = true }
                else { gridMenuClosing = false; gridMenuPresented = true }
            })
        case .exposure: return AnyView(configuredRemoteToolButton(.exposure, movie: movie, active: exposureMode != .off, accessibilityLabel: AppLocalized.resource("cd_remote_zebra"), label: { toolMark(.exposure) }) {
                withAnimation(ZTransferMotion.standard) {
                    exposureMode = switch exposureMode {
                    case .off: .zebra
                    case .zebra: .falseColor
                    case .falseColor: .off
                    }
                    tools.exposure = exposureMode
                }
            })
        case .meter: return AnyView(configuredRemoteToolButton(.meter, movie: movie, active: tools.meter, accessibilityLabel: AppLocalized.resource("remote_tool_meter"), label: {
                toolMark(.meter)
            }) {
                tools.meter.toggle()
            })
        case .pictureControl: return AnyView(configuredRemoteToolButton(.pictureControl, movie: movie,
                active: pictureControlPresented,
                accessibilityLabel: AppLocalized.resource("remote_tool_picture_control"), label: {
                    if let panel = pictureControlPanel, pictureControlPresented {
                        RemotePictureControlToolMark(panel: panel)
                    } else { toolMark(.pictureControl) }
                }) { openPictureControl() })
        case .lut: return AnyView(configuredRemoteToolButton(.lut, movie: movie, active: lutLifetime.isActive, accessibilityLabel: "LUT", label: {
                toolMark(.lut)
            }) {
                closePictureControl()
                selectedField = nil
                developerPanelPresented = false
                model.dismissCameraTool()
                gridMenuPresented = false
                lutMenuClosing = false
                lutMonitor.openMenu()
                lutListPresented = true
            })
        case .desqueeze: return AnyView(configuredRemoteToolButton(.desqueeze, movie: movie, active: effectiveDesqueeze > 1.001,
                             accessibilityLabel: "\(RemoteDisplayOptions.label(for: effectiveDesqueeze))×",
                             label: {
                toolMark(.desqueeze)
            }) {
                withAnimation(ZTransferMotion.standard) {
                    tools.desqueeze = RemoteDisplayOptions.nextDesqueeze(after: effectiveDesqueeze)
                }
            })
        case .level: return AnyView(configuredRemoteToolButton(.level, movie: movie, active: model.levelVisible, accessibilityLabel: AppLocalized.resource("cd_remote_level"), label: { toolMark(.level) }) {
                withAnimation(ZTransferMotion.standard) {
                    tools.level.toggle()
                }
            })
        case .focusFrame: return AnyView(configuredRemoteToolButton(.focusFrame, movie: movie, active: tools.focusFrame, accessibilityLabel: AppLocalized.resource("remote_tool_focus_frame"), label: {
                toolMark(.focusFrame)
            }) {
                withAnimation(ZTransferMotion.standard) { tools.focusFrame.toggle() }
            })
        case .audio: return AnyView(configuredRemoteToolButton(.audio, movie: movie, active: tools.audio, accessibilityLabel: AppLocalized.resource("cd_remote_audio_levels"), label: { toolMark(.audio) }) {
                withAnimation(ZTransferMotion.standard) { tools.audio.toggle() }
            })
        case .whiteBalance: return AnyView(cameraToolButton(.whiteBalance, movie: movie))
        case .focusArea: return AnyView(cameraToolButton(.focusArea, movie: movie))
        case .focusMode: return AnyView(cameraToolButton(.focusMode, movie: movie))
        case .lock: return AnyView(remoteLockButton(movie: movie))
        case .computerControl: return AnyView(configuredRemoteToolButton(.computerControl, movie: movie,
                active: model.computerControlEnabled,
                enabled: model.computerControlToggleAllowed,
                accessibilityLabel: AppLocalized.resource("remote_tool_computer_control"), label: {
                    toolMark(.computerControl)
                }) {
                    model.toggleComputerControl()
                })
        case .rotate: return AnyView(remoteRotateButton)
        }
    }

    private func cameraToolOverlay<Content: View>(_ content: Content, landscape: Bool) -> some View {
        content.overlayPreferenceValue(GeniePopupAnchorPreferenceKey.self) { anchors in
            GeometryReader { proxy in
                if let field = selectedField, let descriptor = model.exposureDescriptors[field] {
                    RemoteParameterPanel(field: field, descriptor: descriptor,
                        anchor: anchors[field.popupTrigger].map { proxy[$0] }, hostSize: proxy.size,
                        landscape: landscape, onSelect: { model.setExposure(field, value: $0) },
                        onDismiss: { selectedField = nil })
                        .id(field)
                }
                if pictureControlPresented, let panel = pictureControlPanel {
                    RemotePictureControlPanel(model: panel, folders: panel.folders,
                        anchor: anchors[.remotePictureControl].map { proxy[$0] }, hostSize: proxy.size,
                        landscape: landscape, canWrite: model.pictureControlWritesAllowed,
                        dismiss: { if pictureControlPanel === panel { closePictureControl() } },
                        chooseFolder: choosePictureControlFolder, pickerActive: pictureControlPicker.active)
                }
                if lutListPresented {
                    RemoteLUTPanel(monitor: lutMonitor,
                        anchor: anchors[.remoteLUT].map { proxy[$0] }, hostSize: proxy.size,
                        landscape: landscape, closing: lutMenuClosing, pickerActive: lutFolderPickerPresented,
                        close: { lutMenuClosing = true }, dismiss: dismissLUTMenu,
                        onChooseFolder: { lutFolderPickerPresented = true })
                }
                if gridMenuPresented {
                    RemoteGridMenu(tools: tools, anchor: anchors[.remoteGrid].map { proxy[$0] },
                        hostSize: proxy.size, landscape: landscape, closing: $gridMenuClosing,
                        dismiss: { gridMenuPresented = false })
                }
                if let panel = model.cameraToolPanel {
                    let trigger: GeniePopupTrigger = switch panel.tool {
                    case .whiteBalance: .remoteWhiteBalance
                    case .focusArea: .remoteFocusArea
                    case .focusMode: .remoteFocusMode
                    }
                    RemoteCameraToolMenuHost(panel: panel, anchor: anchors[trigger].map { proxy[$0] },
                        hostSize: proxy.size, landscape: landscape, canWrite: model.cameraToolWritesAllowed)
                        .id(panel.id)
                }
            }
        }
        .overlay {
            if developerPanelPresented { developerPanel.transition(.opacity) }
        }
        .overlayPreferenceValue(RemoteMonitorHintAnchorKey.self) { anchor in
            RemoteMonitorHintOverlay(anchor: anchor, text: model.monitorHint.text,
                compact: !landscape, animator: monitorHintAnimator)
        }
    }

    private func cameraToolButton(_ tool: RemoteCameraTool, movie: Bool) -> some View {
        let layoutTool: RemoteTool = switch tool {
        case .whiteBalance: .whiteBalance
        case .focusArea: .focusArea
        case .focusMode: .focusMode
        }
        return configuredRemoteToolButton(layoutTool, movie: movie, active: false,
            accessibilityLabel: AppLocalized.resource(layoutTool.titleKey), label: {
                if tool == .focusMode, !editingTools {
                    if let panel = model.cameraToolPanel, panel.tool == .focusMode, panel.loading {
                        RemoteCameraToolLoading()
                    } else {
                        let text = model.focusModeDescriptor.map { descriptor in
                            if RemoteFocusMode.manual(property: descriptor.property, value: descriptor.current) {
                                return "MF"
                            }
                            return RemoteFocusMode.label(property: descriptor.property, value: descriptor.current) ?? "MODE"
                        } ?? "MODE"
                        Text(text == "AF Macro" ? "AF-M" : text)
                            .font(.system(size: 8, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                    }
                } else if let panel = model.cameraToolPanel, !editingTools {
                    RemoteCameraToolMark(panel: panel, tool: tool)
                } else { RemoteCameraToolStaticMark(tool: tool) }
            }) {
                selectedField = nil
                developerPanelPresented = false
                gridMenuPresented = false
                model.openCameraTool(tool)
            }
    }

    private func setEditingTools(_ editing: Bool) {
        pauseOrientationCandidate()
        orientationSession.discardPending()
        selectedField = nil
        model.dismissCameraTool()
        developerPanelPresented = false
        gridMenuPresented = false
        editingTools = editing && !layoutOrientation.isLandscape
        if !editingTools { refreshOrientationCandidate() }
    }

    @ViewBuilder
    private func configuredRemoteToolButton<Label: View>(_ tool: RemoteTool, movie: Bool, active: Bool,
        enabled: Bool = true,
        accessibilityLabel: String, @ViewBuilder label: @escaping () -> Label, action: @escaping () -> Void) -> some View {
        if editingTools && !tool.fixed {
            remoteToolEditButton(tool, movie: movie) { toolMark(tool) }
        } else {
            RemoteDockToolCell(id: tool.id, title: AppLocalized.resource(tool.titleKey), active: active, enabled: enabled && !(editingTools && tool.fixed), action: action) {
                remoteToolButton(active: active, enabled: enabled && !(editingTools && tool.fixed), fixed: tool.fixed, preserveContentColors: tool == .pictureControl, accessibilityLabel: AppLocalized.resource(tool.titleKey), label: label, action: action)
                    .modifier(RemoteToolIconAnchor(tool: tool))
                    .accessibilityIdentifier("remote-tool-\(tool.id)")
            }
        }
    }

    private func remoteToolEditButton<Label: View>(_ tool: RemoteTool, movie: Bool,
        @ViewBuilder label: @escaping () -> Label) -> some View {
        let layout = tools.layout(movie: movie)
        return RemoteToolVisibilityContent(layout: layout, tool: tool) { visible in
            remoteToolButton(active: visible, preserveContentColors: tool == .pictureControl, accessibilityLabel: AppLocalized.resource(tool.titleKey), label: {
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
        orientationSession.pause()
        if locked { tools.lockedRotation = layoutOrientation.rawValue }
        tools.locked = locked
        if showHint { model.showRotationLockHint(locked) }
    }

    private func setToolVisible(_ tool: RemoteTool, _ visible: Bool) {
        if !visible {
            switch tool {
            case .whiteBalance: if model.cameraToolPanel?.tool == .whiteBalance { model.dismissCameraTool() }
            case .focusArea: if model.cameraToolPanel?.tool == .focusArea { model.dismissCameraTool() }
            case .focusMode: if model.cameraToolPanel?.tool == .focusMode { model.dismissCameraTool() }
            case .hd: model.setHDLiveView(false)
            case .lock: setRotationLocked(false, showHint: false)
            case .pictureControl: closePictureControl()
            case .lut: lutMonitor.turnOff(); dismissLUTMenu()
            case .computerControl: if model.computerControlEnabled { model.setComputerControl(false) }
            case .histogram:
                histogramMode = .off
                tools.histogram = .off
            case .grid: tools.grid = .off; gridMenuPresented = false
            case .exposure:
                exposureMode = .off
                tools.exposure = .off
            case .focusFrame: tools.focusFrame = false
            default: break
            }
        }
        tools.layout(movie: model.movieMode).setVisible(tool, visible)
    }

    private func registerFpsTap() {
        withAnimation(ZTransferMotion.standard) { tools.fps.toggle() }
        let now = ProcessInfo.processInfo.systemUptime
        fpsTapCount = now - lastFpsTapAt < 1.5 ? fpsTapCount + 1 : 1
        lastFpsTapAt = now
        if fpsTapCount >= 4 { developerUnlocked = true }
    }

    private func startFocusDiagnostic() {
        let mode = model.movieMode ? "movie" : "photo"
        let transport = isUSBSession ? "USB" : (wirelessMode == .sta ? "STA" : "AP")
        model.startFocusDiagnostic(description: "transport=\(transport) mode=\(mode)")
    }

    private func stopFocusDiagnostic() {
        model.stopFocusDiagnostic()
    }

    /// The Android panel's two video probes are read-only compatibility checks.
    /// The broader capability scan and temporary-property probes remain out of
    /// the iOS surface.
    private var developerPanel: some View {
        RemoteDiagnosticReportReader(output: model.focusDiagnosticOutput) { diagnosticReport in
            let report = diagnosticReport.isEmpty ? persistedFocusDiagnosticReport : diagnosticReport
            let snapshot = developerReportCache.resolve(log: developerLogLines, recording: model.recordingErrorReport,
                focus: report, pictureControl: pictureControlReport)
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
                                let report = model.focusDiagnosticReport.isEmpty ? persistedFocusDiagnosticReport : model.focusDiagnosticReport
                                let fullReport = developerReportCache.resolve(log: developerLogLines,
                                    recording: model.recordingErrorReport, focus: report,
                                    pictureControl: pictureControlReport).copyText
                                guard fullReport.utf8.count <= 180_000 else {
                                    model.showMonitorHint(AppLocalized.resource("picture_control_report_use_share"))
                                    return
                                }
                                UIPasteboard.general.string = fullReport
                                model.showMonitorHint(AppLocalized.resource("code_copied"))
                            }
                            developerPanelButton(systemName: "xmark",
                                                 accessibilityLabel: AppLocalized.resource("cd_close")) {
                                withAnimation(ZTransferMotion.standard) { developerPanelPresented = false }
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text(AppLocalized.resource("remote_focus_diagnostic_hint"))
                                .font(.system(size: 11))
                                .foregroundStyle(ZTransferColors.secondaryText)
                            HStack(spacing: 8) {
                                Button(AppLocalized.resource(model.focusDiagnosticRunning ? "remote_focus_diagnostic_stop" : "remote_focus_diagnostic_start")) {
                                    if model.focusDiagnosticRunning { stopFocusDiagnostic() } else { startFocusDiagnostic() }
                                }
                                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 16))
                                Button(AppLocalized.resource("remote_focus_diagnostic_mark")) {
                                    model.markFocusDiagnostic("movie=\(model.movieMode) recording=\(String(describing: model.state.capture)) focus=\(model.focusModeDescriptor.map { String($0.current) } ?? "unknown")")
                                }
                                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 16))
                                .disabled(!model.focusDiagnosticRunning)
                            }
                            HStack(spacing: 8) {
                                Button(AppLocalized.resource("probe_video_remaining")) {
                                    model.runLegacyVideoDiagnostic()
                                }
                                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 16))
                                .disabled(model.videoDiagnosticBusy || model.recordingBusy || model.cameraToolWriting)
                                Button(AppLocalized.resource("probe_movie_format")) {
                                    model.runMovieFormatDiagnostic()
                                }
                                .buttonStyle(ZTransferGlassButtonStyle(cornerRadius: 16))
                                .disabled(model.videoDiagnosticBusy || model.recordingBusy || model.cameraToolWriting)
                            }
                        }

                        PhotoEffectChooserList(items: Array(snapshot.lines.indices), id: \.self,
                            initialID: snapshot.lines.indices.last, followTailChange: snapshot.lines.last) { index in
                            let line = snapshot.lines[index]
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(line.hasPrefix("!!")
                                                 ? ZTransferColors.accentOrange
                                                 : Color.white.opacity(0.76))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.top, index == 0 ? 6 : 0)
                                .padding(.bottom, index == snapshot.lines.count - 1 ? 6 : 0)
                        }
                        .frame(height: 170)
                        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
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

    private func toolMark(_ tool: RemoteTool) -> some View {
        RemoteToolMark(tool: tool, histogramRGB: histogramMode == .rgb, waveformRGB: tools.waveform == .rgb,
            falseColor: exposureMode == .falseColor, grid: tools.grid, desqueeze: effectiveDesqueeze, locked: tools.locked)
    }

    private func remoteToolButton<Label: View>(
        active: Bool,
        enabled: Bool = true,
        fixed: Bool = false,
        preserveContentColors: Bool = false,
        accessibilityLabel: String,
        @ViewBuilder label: @escaping () -> Label,
        action: @escaping () -> Void
    ) -> some View {
        RemoteMonitorToolButton(active: active, enabled: enabled, fixed: fixed,
            preserveContentColors: preserveContentColors, accessibilityLabel: accessibilityLabel,
            label: label, action: action)
    }

    @ViewBuilder private func reviewButton(large: Bool, sizeScale: CGFloat = 1) -> some View {
        if model.reviewVisible, !editingTools, reviewQueue != nil, reviewSession != nil {
            RemoteReviewEntryButton(large: large, sizeScale: sizeScale,
                enabled: model.reviewAllowed && isSessionConnected && !switchingRotation && !review.active) {
                ZTransferHaptics.shared.play(.navigation)
                closeMonitorPanels()
                review.open()
            }
        }
    }

    private var shutterButton: some View {
        remoteShutter(diameter: 76)
    }

    private func remoteShutter(diameter: CGFloat) -> some View {
        RemoteShutterButton(
            capture: model.state.capture,
            movieMode: model.movieMode,
            enabled: isSessionConnected && !model.cameraToolWriting,
            focusing: model.halfPressVisualActive,
            onQuickTap: { if model.movieMode { model.toggleRecording() } else { model.capture() } },
            onFocusStart: { model.beginHalfPress() },
            onRelease: { model.endHalfPress(fire: $0) },
            diameter: diameter
        )
    }

    private var showCameraRecording: Bool {
        isSessionConnected && model.movieMode && model.state.capture == .recording
    }

    private var remoteViewfinder: some View {
        RemoteViewfinderAspect(aspect: remoteViewfinderAspect) { aspect in
            RemoteViewfinderFrameScope(updates: model.frameUpdates) { size in
                viewfinderContent(size: size, aspect: aspect)
            }
        }
    }

    private func viewfinderContent(size: CGSize, aspect: CGFloat) -> some View {
        let image = model.frameImage
        let meters = RemoteMonitorMeterLayout(size: size,
            landscape: layoutOrientation.isLandscape, movie: model.movieMode,
            showExposure: tools.meter, audioEnabled: isSessionConnected && model.movieMode && tools.audio)
        return ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(RadialGradient(
                    colors: [Color(white: 0.38), Color(white: 0.18)],
                    center: .center,
                    startRadius: 12,
                    endRadius: 420
                ))
            if let image {
                let metadata = model.frameMetadata
                let focusBlock = focusDisplayState(now: ProcessInfo.processInfo.systemUptime, metadata: metadata)
                let cameraFrames = focusBlock == nil ? metadata?.focusFrames ?? [] : []
                RemoteZoomableViewfinder(aspect: aspect, imageSize: image.size, metadata: model.frameMetadata, onFocus: {
                    model.focus(at: $0, coordinateSize: image.size)
                }) {
                    ZStack {
                        if let cgImage = image.cgImage {
                            RemoteLUTImage(image: cgImage, monitor: lutMonitor,
                                source: RemoteViewfinderImage(image: image, aspect: aspect,
                                    size: size))
                                .aspectRatio(aspect, contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            RemoteViewfinderImage(image: image, aspect: aspect,
                                size: size)
                        }
                        if exposureMode == .falseColor, let bitmap = model.frameFalseColorImage {
                            RemoteFalseColorOverlay(image: bitmap, aspect: aspect).equatable()
                        }
                        if tools.grid != .off {
                            RemoteFramingGridOverlay(grid: tools.grid, aspect: aspect).equatable()
                        }
                        if exposureMode == .zebra, let zebraMask = model.frameZebraMask {
                            IOSZebraOverlay(mask: zebraMask, aspect: aspect).equatable()
                        }
                        RemoteFocusLayers(
                            frames: cameraFrames, focused: metadata?.focusJudgement == .focused,
                            phase: model.state.focus.phase, point: model.state.focus.point,
                            nonce: model.state.focus.nonce, marker: model.confirmedFocusMarker,
                            frameReceivedAt: model.frameReceivedAtUptime,
                            halfPressActive: model.halfPressVisualActive, aspect: aspect)
                    }
                }
                .onChange(of: model.frameMetadata) { metadata in
                    guard model.focusDiagnosticRunning else { return }
                    model.displayFocusDiagnostic(focusDisplayState(now: ProcessInfo.processInfo.systemUptime, metadata: metadata)
                        ?? "drawn boxes=\(metadata?.focusFrames.count ?? 0)")
                }
                if exposureMode == .falseColor {
                    RemoteFalseColorLegend()
                        .padding(.top, 22)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .allowsHitTesting(false)
                }
                if tools.meter {
                    RemoteExposureMeterOverlay(ev: model.exposureMeterEV.map(Double.init))
                        .padding(.top, meters.exposureTop)
                        .padding(.trailing, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .allowsHitTesting(false)
                }
                RemoteMonitorScopesOverlay(
                    histogram: model.frameHistogram, histogramRGB: model.frameHistogramRGB,
                    waveformImage: model.frameWaveformImage, histogramMode: histogramMode,
                    waveformMode: tools.waveform,
                    startInset: meters.scopeStartInset,
                    informationInset: layoutOrientation.isLandscape && dispMode == .camera && isSessionConnected
                        ? RemoteDispLayout.informationInset : 0).equatable()
                if model.levelVisible, let roll = model.levelRoll {
                    RemoteHorizonOverlay(roll: Float(roll), pitch: model.levelPitch.map(Float.init)).equatable()
                        .allowsHitTesting(false)
                }
                if meters.audio.height > 0, let levels = model.frameMetadata?.soundLevels {
                    IOSSoundMeter(levels: levels)
                        .frame(width: meters.audio.width, height: meters.audio.height)
                        .clipped()
                        .position(x: meters.audio.midX, y: meters.audio.midY)
                        .allowsHitTesting(false)
                }
            } else if tools.grid != .off {
                RemoteFramingGridOverlay(grid: tools.grid, aspect: aspect).equatable()
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
            if showCameraRecording {
                HStack(spacing: 5) {
                    Circle()
                        .fill(ZTransferColors.statusError)
                        .frame(width: 7, height: 7)
                    RemoteRecordingElapsedText(elapsed: model.cameraRecordingElapsed)
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
            if layoutOrientation.isLandscape {
                // Android mounts the CAMERA readout as soon as the session
                // is connected; storage/detail polling is separately gated
                // by initial live-view readiness. Do not hide the shell
                // while the first frame is still settling.
                if dispMode == .camera, isSessionConnected {
                    monitorCameraDispOverlay
                } else if model.state.liveViewStable, dispMode == .exposure {
                    monitorExposureSummaryOverlay
                }
            } else if model.state.liveViewStable {
                monitorPortraitStatusOverlay
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            // Android ViewfinderCard owns recording feedback; toolbar
            // controls are outside this recording surface.
            if showCameraRecording {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color(red: 1, green: 0.259, blue: 0.302), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
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

    private var remoteViewfinderAspect: CGFloat {
        guard let image = model.frameImage else { return 1.5 * CGFloat(effectiveDesqueeze) }
        return (image.size.width / max(image.size.height, 1)) * CGFloat(effectiveDesqueeze)
    }

    private var monitorCameraDispOverlay: some View {
        let remaining: String? = {
            guard model.movieMode,
                  let remainingMs = model.frameRemainingVideoTimeMs else { return nil }
            return RemoteMonitorTelemetry.remainingTimeLabel(seconds: remainingMs / 1000).map { "[\($0)]" }
        }()
        let items = RemoteMonitorTelemetry.cameraTopRowItems(
            storage: monitorStorageStatusItems,
            movie: model.movieMode,
            movieFormat: model.movieFormatLabel,
            remaining: remaining,
            batteryPercent: model.batteryPercent
        )
        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Text(items.joined(separator: "   ·   "))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, RemoteDispLayout.standbyTrailingReservation)
                if RemoteMonitorTelemetry.cameraShowsStandby(
                    movie: model.movieMode, recording: model.state.capture == .recording
                ) {
                    Text("STBY")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.8))
                        .fixedSize()
                }
            }
            .shadow(color: .black.opacity(0.85), radius: 2)

            Spacer(minLength: 0)

            HStack(spacing: RemoteDispLayout.bottomCellSpacing) {
                monitorCell(label: "MODE", value: monitorModeText)
                monitorCell(label: "WB", value: model.displayWhiteBalanceLabel)
                monitorCell(label: "AF", value: monitorFocusModeText)
            }
            .frame(maxWidth: RemoteDispLayout.bottomMaxWidth, alignment: .leading)
        }
        .padding(.horizontal, RemoteDispLayout.horizontalInset)
        .padding(.vertical, RemoteDispLayout.verticalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private var monitorExposureSummaryOverlay: some View {
        Group {
            if let mode = monitorModeText {
                RemoteStatusBadge(text: mode, weight: .bold)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(10)
            }
        }
        .allowsHitTesting(false)
    }

    private var monitorPortraitStatusOverlay: some View {
        HStack(spacing: 4) {
            if let mode = monitorModeText {
                RemoteStatusBadge(text: mode, weight: .bold)
            }
            if let focus = monitorFocusModeText {
                RemoteStatusBadge(text: focus, weight: .semibold)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func monitorCell(label: String, value: String?) -> some View {
        if let value {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.white.opacity(0.65))
                Text(value)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .shadow(color: .black.opacity(0.85), radius: 2)
        }
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

    private func focusDisplayState(now: TimeInterval, metadata: RemoteLiveViewMetadata?) -> String? {
        let layout = tools.layout(movie: model.movieMode)
        if !tools.focusFrame { return "blocked=tool-off" }
        if !layout.visible(.focusFrame) { return "blocked=tool-hidden" }
        if !isSessionConnected { return "blocked=disconnected" }
        if model.frameReceivedAtUptime <= model.focusValidAfterUptime { return "blocked=before-mode-change" }
        let age = max(0, now - model.frameReceivedAtUptime)
        if model.focusFrameExpired || age >= 0.5 { return "blocked=stale-frame" }
        if metadata?.focusFrames.isEmpty != false {
            return "blocked=no-box \(metadata?.focusFrameStatus ?? "unsupported-header")"
        }
        return nil
    }

    private func pauseOrientationCandidate() {
        orientationStabilityTask?.cancel()
        orientationStabilityTask = nil
        orientationSession.pause()
    }

    private func refreshOrientationCandidate() {
        // Android re-enables its sensor listener after resume/unfreeze. UIDevice
        // may not emit another notification until the phone moves again.
        guard orientationNotificationsActive, !stopCleanupStarted else { return }
        applyDeviceOrientation(UIDevice.current.orientation)
    }

    private func applyDeviceOrientation(_ orientation: UIDeviceOrientation) {
        guard !stopCleanupStarted, scenePhase == .active, !editingTools, !tools.locked, !review.active else {
            pauseOrientationCandidate()
            return
        }
        let target: RemoteLayoutOrientation
        switch orientation {
        case .landscapeLeft: target = .landscapeLeft
        case .landscapeRight: target = .landscapeRight
        case .portrait: target = .portrait
        default:
            pauseOrientationCandidate()
            return
        }
        guard target != orientationSession.candidate else { return }
        orientationStabilityTask?.cancel()
        guard let ticket = orientationSession.observe(target) else { return }
        orientationStabilityTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled, scenePhase == .active, !tools.locked, !editingTools, orientationSession.accepts(ticket, target: target) else { return }
            requestLayoutOrientation(target)
        }
    }

    private func cycleLayoutOrientation() {
        guard !switchingRotation, !editingTools, !tools.locked else { return }
        orientationSession.suppressCurrent()
        orientationStabilityTask?.cancel()
        let target: RemoteLayoutOrientation = switch layoutOrientation {
        case .portrait: .landscapeLeft
        case .landscapeLeft: .landscapeRight
        case .landscapeRight: .portrait
        }
        requestLayoutOrientation(target)
    }

    private func requestLayoutOrientation(_ target: RemoteLayoutOrientation) {
        guard !tools.locked, !editingTools else { return }
        // Android's conflated channel retains only the latest request during a
        // transition, including a request to return to the pre-transition layout.
        if switchingRotation { orientationSession.enqueue(target); return }
        guard target != layoutOrientation else { return }
        switchingRotation = true
        // The native compositor reports actual completion; do not unlock
        // input using a timer that can precede the first rendered frame.
        layoutOrientation = target
    }

    private func finishLayoutRotation() {
        guard switchingRotation else { return }
        switchingRotation = false
        guard !stopCleanupStarted, scenePhase == .active else {
            orientationSession.discardPending()
            return
        }
        if let pending = orientationSession.takePending() { requestLayoutOrientation(pending) }
    }

    private func fitImageRect(in size: CGSize, aspect: CGFloat) -> CGRect {
        guard aspect > 0, size.width > 0, size.height > 0 else { return .zero }
        let fitted = min(size.width / aspect, size.height)
        let width = fitted * aspect
        return CGRect(x: (size.width - width) / 2, y: (size.height - fitted) / 2,
                      width: width, height: fitted)
    }

    private var exposureFields: [RemoteExposureField] { [.exposureCompensation, .iso, .aperture, .shutter] }

    private var exposureGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(exposureFields, id: \.self) { field in exposureTile(field, height: 54) }
        }.padding(.horizontal, 14)
    }

    private func exposureTile(_ field: RemoteExposureField, height: CGFloat) -> some View {
        RemoteExposureTile(field: field, descriptor: model.exposureDescriptors[field],
                                   onOpenList: { gridMenuPresented = false; model.dismissCameraTool(); selectedField = field },
                                   onStep: { model.stepExposure(field, delta: $0) },
                                   autoEnabled: field == .iso && model.autoISODescriptor != nil ? model.autoISOEnabled : nil,
                                   autoToggle: field == .iso && model.autoISODescriptor != nil ?
                                       { model.setAutoISO(!model.autoISOEnabled) } : nil,
                                   autoBusy: model.autoISOBusy,
                                   effectiveISO: model.effectiveISO?.current, tileHeight: height)
            .geniePopupAnchor(field.popupTrigger)
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

private struct RemoteFocusLayers: View {
    let frames: [RemoteLiveViewFocusFrame]
    let focused: Bool
    let phase: RemoteFocusPhase
    let point: RemoteFocusPoint?
    let nonce: UInt64
    let marker: RemoteConfirmedFocusMarker?
    let frameReceivedAt: TimeInterval
    let halfPressActive: Bool
    let aspect: CGFloat
    @State private var handoff = RemoteFocusHandoff()
    @State private var expiredMarker: UInt64?

    var body: some View {
        let fallback = marker.flatMap { marker in
            expiredMarker != marker.nonce ? marker.fallbackPoint(at: ProcessInfo.processInfo.systemUptime) : nil
        }
        let feedback: RemoteFocusPhase = phase != .idle ? phase : (fallback != nil && !halfPressActive ? .locked : .idle)
        let input = RemoteFocusHandoff.Input(nonce: nonce, phase: feedback,
            eligible: marker.map { frameReceivedAt >= $0.confirmedAtUptime } ?? false,
            hasCameraFrames: !frames.isEmpty)
        let visible = handoff.visibility(for: input)
        ZStack {
            if let displayPoint = phase != .idle ? point : fallback {
                RemoteFocusReticle(phase: feedback, point: displayPoint, nonce: nonce, aspect: aspect)
                    .opacity(visible.tap ? 1 : 0)
            }
            IOSLiveViewFocusFramesOverlay(frames: frames, focused: focused,
                                          visible: visible.camera, aspect: aspect)
        }
        .task(id: input) {
            handoff.update(input)
            guard input.candidate else { return }
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard !Task.isCancelled else { return }
            handoff.complete(input)
        }
        .task(id: marker?.nonce) {
            guard let marker, !marker.subjectTracking else { return }
            let remaining = marker.confirmedAtUptime + 3 - ProcessInfo.processInfo.systemUptime
            if remaining > 0 {
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            expiredMarker = marker.nonce
        }
    }
}

private struct RemoteFocusReticle: View {
    let phase: RemoteFocusPhase
    let point: RemoteFocusPoint
    let nonce: UInt64
    let aspect: CGFloat
    @Environment(\.remoteViewfinderZoom) private var zoom
    @State private var appearScale: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            let fitted = min(proxy.size.width / max(aspect, 0.01), proxy.size.height)
            let rect = CGRect(x: (proxy.size.width - fitted * aspect) / 2,
                              y: (proxy.size.height - fitted) / 2,
                              width: fitted * aspect, height: fitted)
            let scale = max(1, zoom)
            let half = min(22 / scale * appearScale, rect.width / 2, rect.height / 2)
            let inset = min(22 / scale * 1.12, rect.width / 2, rect.height / 2)
            let requestedCenter = CGPoint(x: rect.minX + rect.width * CGFloat(point.x),
                                          y: rect.minY + rect.height * CGFloat(point.y))
            let center = CGPoint(
                x: rect.width >= half * 2
                    ? min(max(requestedCenter.x, rect.minX + inset), rect.maxX - inset)
                    : rect.midX,
                y: rect.height >= half * 2
                    ? min(max(requestedCenter.y, rect.minY + inset), rect.maxY - inset)
                    : rect.midY
            )
            let color: Color = switch phase {
            case .locked: Color(red: 103.0 / 255, green: 229.0 / 255, blue: 139.0 / 255)
            case .failed: Color(red: 1, green: 119.0 / 255, blue: 119.0 / 255)
            default: .white
            }
            let path = RemoteFocusReticleCorners(center: center, halfSide: half, zoom: scale)
            ZStack {
                path.stroke(.black.opacity(0.24), style: StrokeStyle(lineWidth: 2.1 / scale, lineCap: .round))
                path.stroke(color.opacity(0.94), style: StrokeStyle(lineWidth: 1.15 / scale, lineCap: .round))
            }
                .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.15), value: phase)
                .onAppear(perform: animateEntry)
                .onChange(of: nonce) { _ in animateEntry() }
        }
        .allowsHitTesting(false)
    }

    private func animateEntry() {
        appearScale = phase == .focusing ? 1.12 : 1
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.18)) { appearScale = 1 }
    }
}

/// Path itself has no interpolatable coordinates. Keep the square extent in
/// a Shape so the 1.12→1 entry actually animates without scaling its stroke.
private struct RemoteFocusReticleCorners: Shape {
    let center: CGPoint
    var halfSide: CGFloat
    let zoom: CGFloat
    var animatableData: CGFloat {
        get { halfSide }
        set { halfSide = newValue }
    }
    func path(in rect: CGRect) -> Path {
        focusCornerPath(center: center, halfWidth: halfSide, halfHeight: halfSide, zoom: zoom)
    }
}

func focusCornerPath(center: CGPoint, halfWidth: CGFloat, halfHeight: CGFloat,
                     zoom: CGFloat = 1) -> Path {
    let scale = max(1, zoom)
    let arm = min(5 / scale, halfWidth * 0.65, halfHeight * 0.65)
    let radius = min(1.4 / scale, arm * 0.45)
    return Path { path in
        for xSign: CGFloat in [-1, 1] {
            for ySign: CGFloat in [-1, 1] {
                let x = center.x + xSign * halfWidth
                let y = center.y + ySign * halfHeight
                path.move(to: CGPoint(x: x - xSign * arm, y: y))
                path.addLine(to: CGPoint(x: x - xSign * radius, y: y))
                path.addQuadCurve(to: CGPoint(x: x, y: y - ySign * radius),
                                  control: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x, y: y - ySign * arm))
            }
        }
    }
}

/// Camera supplied AF rectangles. The tap feedback remains a separate layer;
/// this view preserves the Android handoff delay and fades the last camera
/// geometry instead of flashing a new white marker between packets.
struct IOSLiveViewFocusFramesOverlay: View {
    let frames: [RemoteLiveViewFocusFrame]
    let focused: Bool
    let visible: Bool
    let aspect: CGFloat
    @Environment(\.remoteViewfinderZoom) private var zoom
    private struct Snapshot: Equatable {
        var frames: [RemoteLiveViewFocusFrame] = []
        var focused = false
    }
    @State private var retained = Snapshot()
    private var snapshot: Snapshot { Snapshot(frames: frames, focused: focused) }

    var body: some View {
        GeometryReader { proxy in
            let fitted = min(proxy.size.width / max(aspect, 0.01), proxy.size.height)
            let imageWidth = fitted * aspect
            let imageRect = CGRect(x: (proxy.size.width - imageWidth) / 2,
                                   y: (proxy.size.height - fitted) / 2,
                                   width: imageWidth, height: fitted)
            let display = frames.isEmpty ? retained : snapshot
            let drawFrames = display.frames
            let color: Color = drawFrames.count > 1
                ? Color(red: 1, green: 222.0 / 255, blue: 160.0 / 255)
                : (display.focused ? Color(red: 103.0 / 255, green: 229.0 / 255, blue: 139.0 / 255) : .white)
            Canvas { context, _ in
                guard imageRect.width > 0, imageRect.height > 0 else { return }
                for frame in drawFrames {
                    let center = CGPoint(x: imageRect.minX + imageRect.width * CGFloat(frame.centerX),
                                         y: imageRect.minY + imageRect.height * CGFloat(frame.centerY))
                    let halfWidth = min(imageRect.width * CGFloat(frame.width) / 2, imageRect.width / 2)
                    let halfHeight = min(imageRect.height * CGFloat(frame.height) / 2, imageRect.height / 2)
                    let path = focusCornerPath(center: center, halfWidth: halfWidth,
                                               halfHeight: halfHeight, zoom: zoom)
                    context.stroke(path, with: .color(.black.opacity(0.24)),
                                   style: StrokeStyle(lineWidth: 2.1 / max(1, zoom), lineCap: .round, lineJoin: .round))
                    context.stroke(path, with: .color(color.opacity(0.94)),
                                   style: StrokeStyle(lineWidth: 1.15 / max(1, zoom), lineCap: .round, lineJoin: .round))
                }
            }
            .opacity(visible ? 1 : 0)
            .animation(.easeInOut(duration: 0.16), value: visible)
            .animation(.easeInOut(duration: 0.15), value: color)
            // Keep geometry and judgement from the same packet. Independent
            // change callbacks can otherwise overwrite the retained result
            // when an empty packet and an unfocused judgement arrive together.
            .onChange(of: snapshot) { next in
                if !next.frames.isEmpty { retained = next }
            }
            .onAppear {
                if !frames.isEmpty { retained = snapshot }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Production scope host: data gates and reserved information space stay together.
struct RemoteMonitorScopesOverlay: View, Equatable {
    let histogram: [Int]?
    let histogramRGB: [[Int]]?
    let waveformImage: CGImage?
    let histogramMode: RemoteHistogramMode
    let waveformMode: RemoteWaveformMode
    let startInset: CGFloat
    let informationInset: CGFloat

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.histogram == rhs.histogram && lhs.histogramRGB == rhs.histogramRGB &&
        lhs.waveformImage === rhs.waveformImage && lhs.histogramMode == rhs.histogramMode &&
        lhs.waveformMode == rhs.waveformMode && lhs.startInset == rhs.startInset &&
        lhs.informationInset == rhs.informationInset
    }

    var body: some View {
        GeometryReader { scopeProxy in
            // Android MonitorAnalysisOverlays reserves two equal slots,
            // with a leading lane for the embedded sound meter.
            let usableWidth = max(2, scopeProxy.size.width - startInset - 8)
            let chartWidth = min(138, max(1, (usableWidth - 6) / 2))
            let chartHeight = min(76, max(28, scopeProxy.size.height * 0.29))
            let hasHistogram = histogramMode != .off && histogram != nil
            HStack(alignment: .bottom, spacing: 6) {
                if hasHistogram {
                    RemoteScopeCard(label: histogramMode == .rgb ? "RGB" : "Y′", range: "0–255") {
                        RemoteHistogramOverlay(bins: histogram ?? [],
                            rgb: histogramMode == .rgb ? histogramRGB : nil).equatable()
                    }
                    .frame(width: chartWidth, height: chartHeight)
                }
                if waveformMode != .off, let waveformImage {
                    RemoteScopeCard(label: waveformMode == .rgb ? "RGB" : "Y′", range: "0–100%") {
                        RemoteWaveformOverlay(image: waveformImage)
                    }
                    .frame(width: chartWidth, height: chartHeight)
                }
            }
            .padding(.leading, startInset)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        // Padding reduces the GeometryReader proposal, including chart height.
        .padding(.bottom, informationInset)
        .allowsHitTesting(false)
    }
}

/// Monitor-only labels follow Android ScopeCard; compact cards reserve space for data.
private struct RemoteScopeCard<Content: View>: View {
    let label: String
    let range: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                if proxy.size.height >= 42 {
                    HStack {
                        Text(label).font(.system(size: 8, design: .monospaced))
                        Spacer(minLength: 0)
                        Text(range).font(.system(size: 7, design: .monospaced))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(height: 10)
                }
                content().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
        }
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct RemoteHistogramOverlay: View, Equatable {
    let bins: [Int]
    let rgb: [[Int]]?
    var body: some View {
        Canvas { context, size in
            // Android histogram quarter-scale reference lines remain visible
            // even when the frame has no samples.
            for quarter in 0...4 {
                let x = size.width * CGFloat(quarter) / 4
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
            }
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
    let image: CGImage
    var body: some View {
        Canvas { context, size in
            let showLabels = size.height >= 34
            let plotInset: CGFloat = showLabels ? 15 : 0
            let plotWidth = max(0, size.width - plotInset)
            for quarter in 0...4 {
                let y = CGFloat(quarter) * max(0, size.height - 1) / 4
                var line = Path()
                line.move(to: CGPoint(x: plotInset, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(.white.opacity(quarter == 2 ? 0.18 : 0.10)), lineWidth: 0.5)
            }
            if showLabels {
                for (label, y, anchor) in [("100", CGFloat(0), UnitPoint.topLeading),
                    ("50", size.height / 2, UnitPoint.leading),
                    ("0", size.height, UnitPoint.bottomLeading)] {
                    context.draw(Text(label).font(.system(size: 6, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6)), at: CGPoint(x: 0, y: y), anchor: anchor)
                }
            }
            // Android WaveformOverlay draws the worker-produced density bitmap
            // with medium filtering. One draw replaces up to 32,768 tiny fills.
            context.draw(Image(decorative: image, scale: 1, orientation: .up).interpolation(.medium),
                in: CGRect(x: plotInset, y: 0, width: plotWidth, height: size.height))
        }
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
    }
}

struct RemoteFalseColorOverlay: View, Equatable {
    let image: CGImage
    let aspect: CGFloat

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.image === rhs.image && lhs.aspect == rhs.aspect
    }

    var body: some View {
        GeometryReader { proxy in
            Image(decorative: image, scale: 1, orientation: .up)
                // Android draws the sampled analysis into the fitted display rectangle,
                // including desqueeze; its pixel-buffer aspect must not add a second fit.
                .resizable()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
        }
        .aspectRatio(aspect, contentMode: .fit)
        .allowsHitTesting(false)
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

private struct IOSZebraOverlay: View, Equatable {
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

struct IOSSoundMeter: View {
    let levels: RemoteLiveViewSoundLevels

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            meter(levels.currentLeft, peak: levels.peakLeft, label: "L")
            meter(levels.currentRight, peak: levels.peakRight, label: "R")
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 4)
        .background(.black.opacity(0.56), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.14), lineWidth: 0.5))
    }

    private func meter(_ current: Int, peak: Int, label: String) -> some View {
        let channel = RemoteSoundMeterChannel(current: current, peak: peak)
        return VStack(spacing: 2) {
            Canvas { context, size in
                let count = RemoteSoundMeterChannel.segmentCount
                let height = max(0, (size.height - CGFloat(count - 1)) / CGFloat(count))
                for segment in 0..<count {
                    let active = segment < channel.activeCount
                    let isPeak = segment == channel.peakIndex
                    let zone: Color = segment >= 13 ? .red : segment >= 11 ? .yellow : .white
                    let color = active ? zone.opacity(0.94) : isPeak ? zone.opacity(0.68) : .white.opacity(0.14)
                    let rect = CGRect(x: 0, y: size.height - height - CGFloat(segment) * (height + 1),
                                      width: size.width, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: height / 2), with: .color(color))
                }
            }
            Text(label).font(.system(size: 7, weight: .bold)).foregroundStyle(.white.opacity(0.86))
                .frame(height: 7)
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

/// The one-second countdown only invalidates this badge, not the video layout.
private struct RemoteTrialBadge: View {
    @ObservedObject var meter: RemoteUsageMeter
    var compact = false
    var body: some View {
        if !meter.isPro {
            let seconds = max(0, meter.secondsLeft)
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(ZTransferColors.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, compact ? 0 : 10)
            .padding(.vertical, compact ? 0 : 5)
            .background {
                if !compact { ZTransferGlassSurface(cornerRadius: 9, kind: .panel) }
            }
            .accessibilityIdentifier("remote-trial-countdown")
        }
    }
}


/// Android ExposureMeterOverlay: a missing sample keeps the scale, while an
/// overflow points beyond its end. Motion styling is deferred by project scope.
struct RemoteExposureMeterReading {
    let ev: Double?

    init(ev: Double?) { self.ev = ev.flatMap { $0.isFinite ? $0 : nil } }

    var fraction: CGFloat? { ev.map { CGFloat((3 - min(3, max(-3, $0))) / 6) } }
    var overflowDirection: Int { guard let ev, abs(ev) > 3 else { return 0 }; return ev > 0 ? -1 : 1 }
    var isBalanced: Bool { ev.map { abs($0) < 1.0 / 12 } ?? false }
    var accessibilityValue: String {
        guard let ev else { return "—" }
        return String(format: "%+.1f EV", locale: Locale(identifier: "en_US_POSIX"), ev == 0 ? 0 : ev)
    }
}

struct RemoteExposureMeterOverlay: View {
    let ev: Double?

    var body: some View {
        let reading = RemoteExposureMeterReading(ev: ev)
        Canvas { context, size in
            let inset: CGFloat = 7
            let span = max(0, size.height - inset * 2)
            let right = size.width - 4
            for tick in 0...18 {
                let y = inset + span * CGFloat(tick) / 18
                let length: CGFloat = tick == 9 ? 7 : (tick.isMultiple(of: 3) ? 6 : 3)
                var line = Path()
                line.move(to: CGPoint(x: right - length, y: y))
                line.addLine(to: CGPoint(x: right, y: y))
                context.stroke(line, with: .color(.white.opacity(reading.ev == nil ? 0.3 : 0.7)),
                    style: StrokeStyle(lineWidth: tick == 9 ? 2 : 1, lineCap: .round))
            }
            if let fraction = reading.fraction {
                let y = inset + span * fraction
                var pointer = Path()
                if reading.overflowDirection != 0 {
                    let direction = CGFloat(reading.overflowDirection)
                    pointer.move(to: CGPoint(x: 6.5, y: y + direction * 3))
                    pointer.addLine(to: CGPoint(x: 4, y: y - direction * 2))
                    pointer.addLine(to: CGPoint(x: 9, y: y - direction * 2))
                } else {
                    pointer.move(to: CGPoint(x: 9, y: y))
                    pointer.addLine(to: CGPoint(x: 4, y: y - 3))
                    pointer.addLine(to: CGPoint(x: 4, y: y + 3))
                }
                pointer.closeSubpath()
                context.fill(pointer, with: .color(reading.isBalanced
                    ? Color(red: 110 / 255, green: 231 / 255, blue: 183 / 255) : .white))
            }
        }
        .frame(width: 22, height: 120)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppLocalized.resource("remote_tool_meter"))
        .accessibilityValue(reading.accessibilityValue)
    }
}

/// Only this subtree subscribes to camera frame publication. The content closure
/// reads the latest model values when the subtree updates; evaluating it in the
/// parent would capture a stale image after isolating observation.
struct RemoteFrameScope<Content: View>: View {
    @ObservedObject var updates: RemoteFrameUpdates
    @ViewBuilder let content: () -> Content
    var body: some View { content() }
}

/// Keep observation inside the geometry boundary. With the subscriber outside,
/// GeometryReader can reuse its unchanged closure while packets keep arriving,
/// leaving both the source image and analysis overlays on an obsolete frame.
/// Only the viewfinder content refreshes; stable geometry and controls stay put.
struct RemoteViewfinderFrameScope<Content: View>: View {
    let updates: RemoteFrameUpdates
    @ViewBuilder let content: (CGSize) -> Content

    var body: some View {
        GeometryReader { proxy in
            RemoteFrameScope(updates: updates) { content(proxy.size) }
        }
    }
}

/// User-approved iOS rotation (2026-10-20). Only layout changes are captured;
/// live frames keep their existing leaf observer and camera lifetime. UIKit
/// composites the outgoing image over the new live surface for 220ms, avoiding
/// the old full-monitor alpha=0 interval and any per-frame SwiftUI layout loop.
struct RemoteRotationSurface<Content: View>: UIViewRepresentable {
    let rotation: Double
    var onSettled: () -> Void = {}
    @ViewBuilder let content: () -> Content

    func makeUIView(context: Context) -> RemoteRotationHost { RemoteRotationHost() }
    func updateUIView(_ view: RemoteRotationHost, context: Context) {
        view.onSettled = onSettled
        var transaction = context.transaction
        if let previous = view.rotation, previous != rotation {
            // Resolve the destination once; UIKit owns only the rotation.
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        // Other changes (notably desqueeze) retain their SwiftUI transaction
        // across this hosting boundary instead of jumping to the target size.
        view.scheduleUpdate(content: AnyView(content().environment(\.self, context.environment)),
                            rotation: rotation, transaction: transaction)
    }
    static func dismantleUIView(_ view: RemoteRotationHost, coordinator: ()) {
        view.stop()
        view.host.willMove(toParent: nil)
        view.host.removeFromParent()
    }
}

@MainActor
private final class RemoteRotationContent: ObservableObject {
    @Published var value = AnyView(EmptyView())
}

private struct RemoteRotationContentView: View {
    @ObservedObject var content: RemoteRotationContent
    var body: some View { content.value }
}

@MainActor
final class RemoteRotationHost: UIView {
    private let content: RemoteRotationContent
    let host: UIHostingController<AnyView>
    private(set) var rotation: Double?
    private(set) var animator: UIViewPropertyAnimator?
    private var outgoing: UIView?
    private var generation = 0
    private var pendingContent: (view: AnyView, rotation: Double, transaction: Transaction)?
    private var updateScheduled = false
    var onSettled: () -> Void = {}

    init() {
        let content = RemoteRotationContent()
        self.content = content
        host = UIHostingController(rootView: AnyView(RemoteRotationContentView(content: content)))
        super.init(frame: .zero)
        backgroundColor = .clear
        clipsToBounds = true
        host.view.backgroundColor = .clear
        if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
        addSubview(host.view)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func scheduleUpdate(content: AnyView, rotation: Double, transaction: Transaction) {
        pendingContent = (content, rotation, transaction)
        guard !updateScheduled else { return }
        updateScheduled = true
        // updateUIView runs inside the outer SwiftUI update. Publishing into
        // another graph there is reentrant; hand off once, coalescing updates.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            guard let pending = self.pendingContent else { return }
            self.pendingContent = nil
            withTransaction(pending.transaction) {
                self.update(content: pending.view, rotation: pending.rotation)
            }
        }
    }

    func update(content: AnyView, rotation next: Double) {
        let old = rotation
        let changed = old != nil && old != next && window != nil && bounds.width > 0 && bounds.height > 0
        if changed { stop() }
        let captured = changed ? host.view.snapshotView(afterScreenUpdates: false) : nil
        rotation = next
        // A stable SwiftUI root receives the original transaction. Replacing
        // UIHostingController.rootView discards it and snaps non-rotation changes.
        self.content.value = content
        guard let captured, let old else {
            setNeedsLayout()
            if old != nil && old != next { DispatchQueue.main.async { [weak self] in self?.onSettled() } }
            return
        }
        captured.frame = bounds
        captured.isUserInteractionEnabled = false
        captured.accessibilityElementsHidden = true
        addSubview(captured)
        outgoing = captured
        // Resolve the new layout once, under a retained outgoing surface.
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        var delta = (next - old).truncatingRemainder(dividingBy: 360)
        if delta < -180 { delta += 360 }
        if delta > 180 { delta -= 360 }
        let radians = CGFloat(delta * .pi / 180)
        host.view.transform = CGAffineTransform(rotationAngle: -radians)
        host.view.alpha = 1
        host.view.isUserInteractionEnabled = false
        let ticket = generation
        // Wait for the hosted hierarchy's final layout before starting. The
        // snapshot covers this handoff; no view is ever faded to blank first.
        DispatchQueue.main.async { [weak self, weak captured] in
            guard let self, let captured, self.generation == ticket, self.window != nil else { return }
            self.host.view.layoutIfNeeded()
            let animation = UIViewPropertyAnimator(duration: 0.22,
                controlPoint1: CGPoint(x: 0.4, y: 0), controlPoint2: CGPoint(x: 0.2, y: 1))
            self.animator = animation
            animation.addAnimations {
                self.host.view.transform = .identity
                captured.transform = CGAffineTransform(rotationAngle: radians)
                captured.alpha = 0
            }
            animation.addCompletion { [weak self] _ in
                guard let self, self.generation == ticket else { return }
                self.stop()
                self.onSettled()
            }
            animation.startAnimation()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Bounds/center are safe while the compositor owns the transform.
        host.view.bounds = CGRect(origin: .zero, size: bounds.size)
        host.view.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { stop(); return }
        // Preserve presentation/responder routing (Files picker, accessibility
        // and scene lifecycle) across the native animation boundary.
        if host.parent == nil {
            var responder: UIResponder? = next
            while let current = responder {
                if let parent = current as? UIViewController {
                    parent.addChild(host)
                    host.didMove(toParent: parent)
                    break
                }
                responder = current.next
            }
        }
    }
    func stop() {
        generation += 1
        pendingContent = nil
        animator?.stopAnimation(true)
        animator = nil
        outgoing?.removeFromSuperview()
        outgoing = nil
        host.view.transform = .identity
        host.view.alpha = 1
        host.view.isUserInteractionEnabled = true
    }
}
