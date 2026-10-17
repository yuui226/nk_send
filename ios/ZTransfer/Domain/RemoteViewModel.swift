import AVFoundation
import Foundation
import UIKit

@MainActor
final class RemoteViewModel: ObservableObject {
    @Published private(set) var state = RemoteState() {
        didSet {
            if oldValue.liveViewStable != state.liveViewStable { restartExposureMeter() }
        }
    }
    @Published private(set) var frameImage: UIImage?
    @Published private(set) var frameData: Data?
    @Published private(set) var frameMetadata: RemoteLiveViewMetadata?
    @Published private(set) var focusDiagnosticReport = ""
    @Published private(set) var focusDiagnosticRunning = false
    @Published private(set) var frameHistogram: [Int]?
    @Published private(set) var frameHistogramRGB: [[Int]]?
    @Published private(set) var frameWaveform: [[Int]]?
    @Published private(set) var frameFalseColorPixels: [UInt32]?
    @Published private(set) var frameFalseColorSize: CGSize = .zero
    @Published private(set) var exposureMeterEV: Float?
    private var exposureMeterTask: Task<Void, Never>?
    private var exposureMeterExpiryTask: Task<Void, Never>?
    private var exposureMeterGeneration: UInt64 = 0
    private var exposureMeterEnabled = false
    private var exposureMeterForeground = true
    @Published private(set) var frameZebraMask: RemoteZebraMask?
    @Published private(set) var exposureDescriptors: [RemoteExposureField: RemotePropertyDescriptor] = [:]
    private var exposureDescriptorCache: [Bool: [RemoteExposureField: RemotePropertyDescriptor]] = [:]
    @Published private(set) var movieMode = false {
        didSet {
            if oldValue != movieMode {
                restartExposureMeter()
                setDisplayDetailsMonitoring(displayDetailsMonitoringEnabled)
                setMovieFormatMonitoring(movieFormatMonitoringEnabled)
            }
        }
    }
    @Published private(set) var movieFormatLabel: String?
    @Published private(set) var monitorStorageFreeBytes: [UInt32: Int64] = [:]
    @Published private(set) var monitorStorageSlotCount = 0
    @Published private(set) var monitorStorageSlotByID: [UInt32: Int] = [:]
    @Published private(set) var displayWhiteBalanceLabel: String?
    @Published private(set) var videoDiagnosticLog = ""
    @Published private(set) var computerControlLog = ""
    @Published private(set) var videoDiagnosticBusy = false
    @Published private(set) var cameraToolPanel: RemoteCameraToolController?
    @Published private(set) var cameraToolWriting = false
    @Published private(set) var computerControlEnabled = false
    @Published private(set) var computerControlBusy = false
    private var computerControlTask: Task<Void, Never>?
    private var retiringCameraTools: [UUID: Task<Void, Never>] = [:]
    // Android HD changes VGA/XGA size independently of enhanced-frame support.
    @Published private(set) var hdLiveView = false
    @Published private(set) var autoISODescriptor: RemotePropertyDescriptor?
    @Published private(set) var autoISOBusy = false
    @Published private(set) var effectiveISO: RemotePropertyDescriptor?
    private var autoISOMovieMode: Bool?
    private var autoISOCommandTask: Task<Void, Never>?
    private var effectiveISOTask: Task<Void, Never>?
    private var effectiveISOGeneration = 0
    private var pendingSets: [RemoteProperty: Task<Void, Never>] = [:]
    private var pendingSetGenerations: [RemoteProperty: Int] = [:]
    @Published private(set) var focusModeDescriptor: RemotePropertyDescriptor?
    @Published private(set) var recordingSeconds = 0
    @Published private(set) var localRecordingPhase: RemoteLocalRecordingPhase = .idle
    @Published private(set) var localRecordingSeconds = 0
    @Published private(set) var monitorHint = RemoteMonitorHint()
    @Published private(set) var recordingErrorReport = ""
    var localRecordingHint: String? { monitorHint.message(for: .localRecording) }
    var interactionHint: String? { monitorHint.message(for: .interaction) }
    @Published private(set) var confirmedFocusMarker: RemoteConfirmedFocusMarker?
    @Published private(set) var halfPressVisualActive = false
    @Published private(set) var frameReceivedAtUptime: TimeInterval = 0
    @Published private var recordingOperations = RemoteRecordingOperationGate()
    @Published private(set) var levelPitch: Double?
    @Published private(set) var levelRoll: Double?
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var trialEnded = false
    let usageMeter: RemoteUsageMeter
    private let premiumAccess: PremiumAccess

    var recordingBusy: Bool { recordingOperations.isBusy }
    var recordingHint: String? { monitorHint.message(for: .cameraRecording) }
    var transportLossWasNotified: Bool { transportLossNotified }


    private let camera: RemoteCameraControlling
    private let onTransportLost: (() -> Void)?
    private let haptics: ZTransferHaptics
    private let recordingDirectory: URL?
    private var transportLossNotified = false
    private var frameTask: Task<Void, Never>?
    private var modeTask: Task<Void, Never>?
    private var batteryTask: Task<Void, Never>?
    private var storageTask: Task<Void, Never>?
    private var pollingDelays: [UUID: Task<Void, Error>] = [:]
    private var movieFormatGeneration = 0
    private var movieFormatReadGeneration = 0
    private var movieFormatDescriptor: RemotePropertyDescriptor?
    private var movieFormatDescriptorResolved = false
    private var movieFormatTask: Task<Void, Never>?
    private var displayDetailsTask: Task<Void, Never>?
    private var videoDiagnosticTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    @Published private(set) var levelVisible = false
    private var levelGeneration = 0
    private var clearFrameOnNextSession = true
    private var restartLiveView = false
    private var liveViewPauseRequested = false
    private var liveViewPaused = false
    private var adoptStartedLiveView = false
    private var disposed = false
    @Published private(set) var initialLoaded = false {
        didSet { if oldValue != initialLoaded { restartExposureMeter() } }
    }
    private var batteryDescriptor: RemotePropertyDescriptor?
    private var movieFormatMonitoringEnabled = true
    private var storageMonitoringEnabled = false
    private var storageUnsupported = false
    private var storageGeneration: UInt64 = 0
    private var monitorStorageIDsCache: [UInt32]?
    private var displayDetailsMonitoringEnabled = false
    private var displayDetailsGeneration: UInt64 = 0
    @Published private(set) var exposureProgram: RemotePropertyDescriptor?
    @Published private(set) var focusFrameExpired = false
    @Published private(set) var focusValidAfterUptime = 0.0
    private var focusExpiryTask: Task<Void, Never>?
    private var focusHideTask: Task<Void, Never>?
    private var focusModeRefreshGeneration: UInt64 = 0
    private var halfPressTask: Task<Void, Never>?
    private var tapFocusTask: Task<Void, Never>?
    private var halfPressHeld = false
    private var focusAreaPoint = RemoteFocusPoint(x: 0.5, y: 0.5)
    private var confirmedFocusNonce: UInt64 = 0
    private var recordingTimerTask: Task<Void, Never>?
    private var recordingCommandTask: Task<Void, Never>?
    private var recordingCommandInFlight: RemoteRecordingCommand?
    private var captureTask: Task<Void, Never>?
    private var captureObjectAdded = false
    private var lastStopCommandAt: ContinuousClock.Instant?
    private var monitorHintTask: Task<Void, Never>?
    var recordingDesqueeze: Double = 1
    private var recordingHintHostActive = true
    private var localRecordingID = UUID()
    private var localRecorder: RemoteViewfinderRecorder?
    private var localRecordingTask: Task<Void, Never>?
    private var localRecordingTimerTask: Task<Void, Never>?
    private var localRecordingSavedTask: Task<Void, Never>?
    private var movieCleanupTask: Task<Void, Never>?
    private var movieSessionReleaseInProgress = false
    private var movieCompletionSequence = 0
    private var stopMovieOnExit = false
    private var started = false
    // Teardown is cooperative. Cancelling an in-flight PTP request can
    // invalidate the camera session before the photo list resumes.
    private var stopRequested = false
    private var cleanupTask: Task<Void, Never>?
    private var cleanupComplete = false
    private var lastFrameAt: ContinuousClock.Instant?
    private var frameDecodeGeneration: UInt64 = 0
    private let makeLocalRecorder: @MainActor (RemoteViewfinderRecorder.Configuration) -> RemoteViewfinderRecorder
    private let onRecordingSaveFailure: @MainActor (String) -> Void
    private let requestMicrophonePermission: (@MainActor () async -> Bool)?
    private let focusDiagnostic = RemoteLiveViewFocusDiagnostic()
    private var histogramEnabled = false
    private var zebraEnabled = false
    private var waveformMode: RemoteWaveformMode = .off
    private var falseColorEnabled = false
    private var histogramRGBEnabled = false
    private lazy var frameDecoder = RemoteFrameDecodePipeline { [weak self] decoded in
        self?.acceptDecodedFrame(decoded)
    }

    init(camera: RemoteCameraControlling, recordingDirectory: URL? = nil,
         onTransportLost: (() -> Void)? = nil,
         haptics: ZTransferHaptics = .shared,
         entitlements: PremiumEntitlementStore = .shared, freeUsage: FreeUsageStore = .shared,
         requestMicrophonePermission: (@MainActor () async -> Bool)? = nil,
         onRecordingSaveFailure: @escaping @MainActor (String) -> Void = { RemoteRecordingSaveNotice.shared.post($0) },
         makeLocalRecorder: @escaping @MainActor (RemoteViewfinderRecorder.Configuration) -> RemoteViewfinderRecorder = { RemoteViewfinderRecorder(configuration: $0) }) {
        self.makeLocalRecorder = makeLocalRecorder
        self.onRecordingSaveFailure = onRecordingSaveFailure
        self.requestMicrophonePermission = requestMicrophonePermission
        self.camera = camera
        self.recordingDirectory = recordingDirectory
        self.onTransportLost = onTransportLost
        self.haptics = haptics
        premiumAccess = entitlements.access
        usageMeter = RemoteUsageMeter(entitlements: entitlements, usage: freeUsage)
        usageMeter.onLostPremium = { [weak self] in self?.stopLocalRecording() }
        usageMeter.onExhausted = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Finish writing the recording before closing monitoring.
                await stopAndWait()
                trialEnded = true
            }
        }
    }

    func start() {
        guard frameTask == nil, !disposed else { return }
        stopRequested = false
        storageUnsupported = false
        storageTask?.cancel()
        storageTask = nil
        movieFormatTask?.cancel()
        movieFormatTask = nil
        storageGeneration &+= 1
        monitorStorageIDsCache = nil
        monitorStorageFreeBytes = [:]
        monitorStorageSlotCount = 0
        monitorStorageSlotByID = [:]
        displayDetailsTask?.cancel()
        displayDetailsTask = nil
        displayDetailsGeneration &+= 1
        displayWhiteBalanceLabel = nil
        transportLossNotified = false
        state = state.applying(.startRequested)
        frameTask = Task { [weak self] in
            guard let self else { return }
            await camera.setRemoteActive(true)
            if !stopRequested {
                let controlModeSet = await camera.hasRemoteControlMode()
                let diagnosticControlModeSet = await camera.hasRemoteDiagnosticControlMode()
                computerControlEnabled = controlModeSet && diagnosticControlModeSet
                if camera.isUSB, controlModeSet, !computerControlEnabled {
                    await releaseMovieSessionToStandby(resumeLiveView: false)
                }
                // RemoteScreen: selector -> matching exposure group -> Auto ISO
                // -> exposure mode -> focus -> battery, before starting Live View.
                movieMode = false
                movieMode = (try? await camera.remoteMovieMode()) ?? false
                state.movieMode = movieMode
                await loadExposure(movie: movieMode)
                if !stopRequested { exposureProgram = try? await camera.remoteProperty(.exposureProgram) }
                if !stopRequested { await refreshFocusMode() }
                if !stopRequested { await refreshBattery() }
                initialLoaded = !stopRequested
                if initialLoaded {
                    await refreshMovieFormat()
                    setMovieFormatMonitoring(movieFormatMonitoringEnabled)
                    if displayDetailsMonitoringEnabled {
                        setDisplayDetailsMonitoring(true)
                    }
                }
            }
            if initialLoaded { startPolling() }
            while !Task.isCancelled && !stopRequested {
                while liveViewPauseRequested && !stopRequested {
                    liveViewPaused = true
                    try? await waitForPolling(for: .milliseconds(10))
                }
                liveViewPaused = false
                restartLiveView = false
                frameDecodeGeneration &+= 1
                let decodeGeneration = frameDecodeGeneration
                if clearFrameOnNextSession {
                    invalidateFocusFrame()
                    clearFrameOnNextSession = false
                    clearDisplayedFrame()
                }
                await frameDecoder.reset(generation: decodeGeneration)
                await applyFrameAnalysis()
                state = state.applying(.startRequested)
                lastFrameAt = nil
                do {
                    if adoptStartedLiveView {
                        adoptStartedLiveView = false
                    } else {
                        let size = RemotePropertyDescriptor(property: .liveViewImageSize, dataType: 0x0002,
                                                            writable: true, current: 2, values: [1, 2, 3])
                        try? await camera.setRemoteProperty(size, value: hdLiveView ? 3 : 2)
                        if stopRequested { break }
                        try await camera.startLiveView()
                    }
                    if stopRequested { break }
                    started = true
                    state = state.applying(.deviceReady)
                    if camera.isUSB { try? await waitForPolling(for: .milliseconds(750)) }
                    guard !stopRequested else { break }
                    state.liveViewStable = !camera.isUSB
                    updateEffectiveISOPolling()
                    var successes = 0
                    var errors = 0
                    var windowStart: ContinuousClock.Instant?
                    var intervals = 0
                    while !Task.isCancelled && !stopRequested && !restartLiveView {
                        do {
                            let packet = try await camera.liveViewFrame()
                            errors = 0
                            successes += 1
                            guard !stopRequested else { break }
                            let now = ContinuousClock.now
                            var fps = state.fps
                            if let previous = windowStart {
                                intervals += 1
                                let duration = previous.duration(to: now)
                                let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
                                if seconds >= 1 { fps = Double(intervals) / seconds; intervals = 0; windowStart = now }
                            } else { windowStart = now; fps = 0 }
                            let stable = !camera.isUSB || successes >= 8
                            if stable != state.liveViewStable {
                                state.liveViewStable = stable
                                updateEffectiveISOPolling()
                            }
                            await frameDecoder.submit(.init(packet: packet, fps: fps,
                                                            generation: decodeGeneration))
                        } catch is CancellationError { break }
                        catch PTPSessionError.responseCode(PTPConstants.deviceBusy) {
                            // Busy is not a failed frame and does not count toward restart.
                            try? await waitForPolling(for: .milliseconds(40))
                        } catch {
                            if Self.isTransportFailure(error) { notifyTransportLost(); break }
                            errors += 1
                            if errors >= 3 { break }
                            try? await waitForPolling(for: .milliseconds(300))
                        }
                    }
                    state.liveViewStable = false
                    updateEffectiveISOPolling()
                    state.fps = 0
                    await camera.endLiveView()
                    started = false
                    if !stopRequested && !restartLiveView { try? await waitForPolling(for: .seconds(2)) }
                } catch is CancellationError { break }
                catch {
                    if Self.isTransportFailure(error) { notifyTransportLost(); break }
                    state = state.applying(.frameLost)
                    // Android retries failed LV startup for the lifetime of the page.
                    if !stopRequested { try? await waitForPolling(for: .seconds(3)) }
                }
            }
            await camera.endLiveView()
            started = false
        }
    }

    private var cameraBusy: Bool {
        state.capture == .capturing || state.capture == .recording || recordingBusy
    }

    private func startPolling() {
        modeTask = Task { [weak self] in
            guard let self else { return }
            var pollTick = 0
            while !Task.isCancelled && !stopRequested {
                if !state.liveViewStable {
                    try? await waitForPolling(for: .milliseconds(600))
                    // RemoteScreen's recovery loop retries a failed USB
                    // standby release in bounded batches, without competing
                    // with another Live View stream or clearing manual PC.
                    if !cameraBusy && !computerControlBusy && !stopRequested && camera.isUSB,
                       await camera.hasRemoteControlMode(),
                       !(await camera.hasRemoteDiagnosticControlMode()) {
                        await releaseMovieSessionToStandby(resumeLiveView: true)
                        continue
                    }
                    if !cameraBusy && !stopRequested { await refreshMovieMode() }
                    continue
                }
                let events = (try? await camera.remoteEvents()) ?? []
                var changedProperties = Set<RemoteProperty>()
                var refreshSelector = false
                for event in events where !stopRequested {
                    switch event.code {
                    case 0x4002, 0xC101:
                        if state.capture == .capturing { captureObjectAdded = true }
                    case 0xC10A:
                        if lastStopCommandAt.map({ $0.duration(to: .now) > .seconds(2) }) ?? true {
                            setRecording(true)
                        }
                    case 0xC108, 0xC105:
                        movieCompletionSequence &+= 1
                        setRecording(false)
                        if !recordingBusy { scheduleMovieStandbyCleanup() }
                    case 0x4006:
                        guard let property = RemoteProperty(rawValue: event.handle),
                              changedProperties.insert(RemoteExposureParameters.canonical(property)).inserted else { continue }
                        if property == .liveViewSelector { refreshSelector = true }
                        else { await handlePropertyChanged(event.handle) }
                    default: break
                    }
                }
                // Process completion/interruption from the entire batch before
                // changing modes, as in Android's sole GetEvent consumer.
                if refreshSelector && state.capture != .recording && !recordingBusy && !stopRequested { await refreshMovieMode() }
                pollTick += 1
                if pollTick % 5 == 0 && !refreshSelector && !cameraBusy && !stopRequested { await refreshMovieMode() }
                try? await waitForPolling(for: .milliseconds(state.capture == .capturing ? 150 : 600))
            }
        }
        batteryTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && !stopRequested {
                await pause(for: .seconds(120))
                while !stopRequested && (!state.liveViewStable || cameraBusy) {
                    do { try await waitForPolling(for: .seconds(1)) } catch { return }
                }
                if !stopRequested { await refreshBattery() }
            }
        }
        startStoragePollingIfNeeded()
    }

    /// Camera DISP's storage cards are an idle background poll. The task is
    /// kept separate from event polling so recording/capture can defer it
    /// without delaying the monitor's property and frame loops.
    func setStorageMonitoring(_ enabled: Bool) {
        guard enabled != storageMonitoringEnabled else { return }
        storageMonitoringEnabled = enabled
        storageGeneration &+= 1
        storageTask?.cancel()
        storageTask = nil
        if !enabled {
            // Android recreates the monitor effect when DISP leaves CAMERA;
            // a previous 0x2005 capability result must not survive that
            // composition boundary.
            storageUnsupported = false
            monitorStorageIDsCache = nil
            monitorStorageFreeBytes = [:]
            monitorStorageSlotCount = 0
            monitorStorageSlotByID = [:]
            return
        }
        guard !storageUnsupported, !stopRequested else {
            monitorStorageFreeBytes = [:]
            return
        }
        startStoragePollingIfNeeded()
    }

    private func startStoragePollingIfNeeded() {
        guard storageMonitoringEnabled, storageTask == nil,
              !storageUnsupported, !stopRequested else { return }
        let generation = storageGeneration
        storageTask = Task { [weak self] in
            guard let self else { return }
            while storageMonitorActive(generation: generation) {
                if state.session != .ready || cameraBusy || state.capture != .idle {
                    try? await waitForPolling(for: .milliseconds(250))
                    continue
                }
                await refreshMonitorStorage()
                if !storageMonitorActive(generation: generation) { break }
                try? await waitForPolling(for: .seconds(30))
            }
            if generation == storageGeneration { storageTask = nil }
        }
    }

    /// Camera DISP keeps the readable white-balance descriptor and refreshes
    /// its scalar value every two seconds. A capture/record/tool write pauses
    /// the read while retaining the last descriptor and visible label.
    func setDisplayDetailsMonitoring(_ enabled: Bool) {
        displayDetailsMonitoringEnabled = enabled
        displayDetailsGeneration &+= 1
        displayDetailsTask?.cancel()
        displayDetailsTask = nil
        displayWhiteBalanceLabel = nil
        guard enabled, !stopRequested else {
            displayWhiteBalanceLabel = nil
            return
        }
        let generation = displayDetailsGeneration
        let mode = movieMode
        displayDetailsTask = Task { [weak self] in
            guard let self else { return }
            var descriptor: RemotePropertyDescriptor?
            var initial = true
            while !Task.isCancelled && generation == displayDetailsGeneration && displayDetailsMonitoringEnabled && !stopRequested {
                guard state.session == .ready, !cameraBusy, state.capture == .idle else {
                    try? await waitForPolling(for: .milliseconds(100))
                    continue
                }
                do {
                    let value: RemotePropertyDescriptor?
                    if initial {
                        descriptor = try await camera.remoteCameraTool(.whiteBalance, movie: mode)
                        value = descriptor
                        initial = false
                    } else if let currentDescriptor = descriptor {
                        value = try await camera.refreshRemoteProperty(currentDescriptor)
                    } else { break }
                    guard !Task.isCancelled, generation == displayDetailsGeneration,
                          displayDetailsMonitoringEnabled, mode == movieMode, !stopRequested else { break }
                    let deviceModel = await camera.remoteDeviceModel()
                    guard !Task.isCancelled, generation == displayDetailsGeneration,
                          displayDetailsMonitoringEnabled, mode == movieMode, !stopRequested else { break }
                    if let descriptor = value,
                       let key = RemoteCameraTool.whiteBalance.labelResource(
                           property: descriptor.property.rawValue, value: descriptor.current,
                           model: deviceModel, dataType: descriptor.dataType) {
                        displayWhiteBalanceLabel = AppLocalized.resource(key)
                    } else {
                        displayWhiteBalanceLabel = nil
                    }
                } catch is CancellationError {
                    break
                } catch {
                    guard !Task.isCancelled, generation == displayDetailsGeneration,
                          displayDetailsMonitoringEnabled, mode == movieMode, !stopRequested else { break }
                    displayWhiteBalanceLabel = nil
                }
                try? await waitForPolling(for: .seconds(2))
            }
            if generation == displayDetailsGeneration { displayDetailsTask = nil }
        }
    }

    private func storageMonitorActive(generation: UInt64) -> Bool {
        !Task.isCancelled && generation == storageGeneration && storageMonitoringEnabled && !storageUnsupported && !stopRequested
    }

    private func storagePollAllowed(generation: UInt64) -> Bool {
        storageMonitorActive(generation: generation) && state.session == .ready && !cameraBusy && state.capture == .idle
    }

    func refreshMonitorStorage() async {
        let generation = storageGeneration
        guard storagePollAllowed(generation: generation) else { return }
        do {
            let ids: [UInt32]
            if let cached = monitorStorageIDsCache {
                ids = cached
            } else {
                let discovered = try await camera.monitorStorageIDs()
                guard storageMonitorActive(generation: generation) else { return }
                let usable = Array(Set(discovered.filter { $0 != 0 && $0 != .max })).sorted()
                monitorStorageIDsCache = usable
                monitorStorageSlotCount = usable.count
                monitorStorageSlotByID = Dictionary(uniqueKeysWithValues: usable.enumerated().map { ($0.element, $0.offset + 1) })
                ids = usable
            }
            var values: [UInt32: Int64] = [:]
            for id in ids {
                // Android waits before every card, including when capture
                // became busy during the preceding card's command.
                while !storagePollAllowed(generation: generation) {
                    guard storageMonitorActive(generation: generation) else { return }
                    do { try await waitForPolling(for: .milliseconds(250)) } catch { return }
                }
                do {
                    let free = try await camera.monitorFreeBytes(storageID: id, allowed: { [weak self] in
                        await self?.storagePollAllowed(generation: generation) == true
                    })
                    guard storageMonitorActive(generation: generation) else { return }
                    if let free {
                        values[id] = free
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard storageMonitorActive(generation: generation) else { return }
                    if case PTPSessionError.responseCode(0x2005) = error {
                        storageUnsupported = true
                        // supported.clear()/break retains valid earlier cards
                        // in this cycle's `next` list, then stops future polls.
                        monitorStorageFreeBytes = values
                        return
                    }
                    // Android drops only this card for a transient or
                    // malformed response and retries it in the next cycle.
                }
            }
            guard storageMonitorActive(generation: generation) else { return }
            monitorStorageFreeBytes = values
        } catch is CancellationError {
            return
        } catch {
            guard storageMonitorActive(generation: generation) else { return }
            // A failed ID discovery hides stale cards and is retried after the
            // normal 30-second monitor interval.
            monitorStorageFreeBytes = [:]
            monitorStorageSlotCount = 0
            monitorStorageSlotByID = [:]
        }
    }

    private func handlePropertyChanged(_ raw: UInt32) async {
        guard !stopRequested else { return }
        if [UInt32(0x501C), 0xD05D, 0xD1F8].contains(raw) { invalidateFocusFrame() }
        if raw == RemoteProperty.batteryLevel.rawValue {
            await refreshBattery()
            return
        }
        if raw == RemoteProperty.liveViewSelector.rawValue {
            if !cameraBusy { await refreshMovieMode() }
            return
        }
        if raw == RemoteProperty.movieFormat.rawValue {
            await refreshMovieFormat()
            return
        }
        if raw == RemoteProperty.exposureProgram.rawValue {
            exposureProgram = try? await camera.remoteProperty(.exposureProgram)
            await loadExposure(movie: movieMode, preservingPending: true)
            return
        }
        if [RemoteProperty.focusMode, .stillFocusMode, .nikonAFMode].contains(where: { $0.rawValue == raw }) {
            await refreshFocusMode()
            return
        }
        if [RemoteProperty.nikonAutoISO, .nikonAutoISOAlternate, .movieAutoISO].contains(where: { $0.rawValue == raw }) {
            await refreshAutoISO()
            return
        }
        if raw == RemoteProperty.nikonISOControlSensitivity.rawValue, autoISOEnabled {
            if let effectiveISO, let next = try? await camera.refreshRemoteProperty(effectiveISO), !stopRequested {
                self.effectiveISO = next
            }
            return
        }
        guard let reported = RemoteProperty(rawValue: raw),
              pendingSets[RemoteExposureParameters.canonical(reported)] == nil else { return }
        for mode in [false, true] {
            for field in [RemoteExposureField.exposureCompensation, .iso, .aperture, .shutter]
            where RemoteExposureParameters.compatibleProperties(for: field, movie: mode)
                .contains(where: { RemoteExposureParameters.canonical($0) == RemoteExposureParameters.canonical(reported) }) {
                if let updated = await readExposure(field, movie: mode), !stopRequested {
                    // Android keeps both photo and movie maps current even
                    // while only one group is rendered.
                    exposureDescriptorCache[mode, default: [:]][field] = updated
                    if mode == movieMode { exposureDescriptors[field] = updated }
                }
            }
        }
    }

    private func pause(for duration: Duration) async {
        let deadline = ContinuousClock.now.advanced(by: duration)
        while !stopRequested && !Task.isCancelled && ContinuousClock.now < deadline {
            try? await waitForPolling(for: min(.milliseconds(100), ContinuousClock.now.duration(to: deadline)))
        }
    }

    private func refreshMovieMode() async {
        guard !stopRequested,
              let nextMovie = try? await camera.remoteMovieMode(), !stopRequested else { return }
        let changed = nextMovie != movieMode
        if changed {
            dismissCameraTool()
            invalidateFocusFrame()
            movieMode = nextMovie
            state.movieMode = nextMovie
            await refreshFocusMode()
        }
        // RemoteScreen.refreshMovieMode clears stale recording/application
        // state on the photo selector even when no completion event arrived.
        // USB ControlMode ownership is guarded by the repository; changing the
        // physical selector does not itself restart Live View or release PC.
        if !nextMovie {
            if state.capture == .recording { setRecording(false) }
            await camera.clearMovieApplicationMode(force: false)
        }
        if changed {
            await loadExposure(movie: nextMovie)
            await refreshMovieFormat()
        }
    }

    private func refreshMovieFormat() async {
        guard movieFormatMonitoringEnabled, movieMode, !stopRequested else {
            movieFormatLabel = nil
            return
        }
        let generation = movieFormatGeneration
        movieFormatReadGeneration &+= 1
        let readGeneration = movieFormatReadGeneration
        let resolving = !movieFormatDescriptorResolved
        let descriptor: RemotePropertyDescriptor?
        if resolving {
            descriptor = try? await camera.remoteProperty(.movieFormat)
        } else if let cached = movieFormatDescriptor {
            descriptor = try? await camera.refreshRemoteProperty(cached)
        } else { return }
        // A cancelled monitor or an older event read must not publish into a
        // reopened DISP session. Drain the camera request before discarding it.
        guard !Task.isCancelled, !stopRequested, movieMode,
              movieFormatMonitoringEnabled, generation == movieFormatGeneration,
              readGeneration == movieFormatReadGeneration else { return }
        if resolving {
            movieFormatDescriptorResolved = true
            movieFormatDescriptor = descriptor?.dataType == 0x0008 ? descriptor : nil
        }
        guard let descriptor, movieFormatDescriptor != nil else {
            movieFormatLabel = nil
            return
        }
        movieFormatLabel = RemoteMonitorTelemetry.movieFormatLabel(
            dataType: descriptor.dataType, raw: descriptor.current)
    }

    func setMovieFormatMonitoring(_ enabled: Bool) {
        movieFormatMonitoringEnabled = enabled
        movieFormatGeneration &+= 1
        movieFormatDescriptor = nil
        movieFormatDescriptorResolved = false
        let generation = movieFormatGeneration
        movieFormatTask?.cancel()
        movieFormatTask = nil
        movieFormatLabel = nil
        guard enabled, !stopRequested else { return }
        movieFormatTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && generation == movieFormatGeneration && movieFormatMonitoringEnabled && !stopRequested {
                guard state.session == .ready, movieMode, !cameraBusy, state.capture == .idle else {
                    try? await waitForPolling(for: .milliseconds(250))
                    continue
                }
                await refreshMovieFormat()
                try? await waitForPolling(for: .seconds(10))
            }
            if generation == movieFormatGeneration { movieFormatTask = nil }
        }
    }

    private func refreshBattery() async {
        guard !stopRequested else { return }
        let next: RemotePropertyDescriptor?
        if let batteryDescriptor { next = try? await camera.refreshRemoteProperty(batteryDescriptor) }
        else { next = try? await camera.remoteProperty(.batteryLevel) }
        guard let next, !stopRequested else { return }
        batteryDescriptor = next
        batteryPercent = next.batteryPercentage
    }

    private func refreshFocusMode() async {
        focusModeRefreshGeneration &+= 1
        let generation = focusModeRefreshGeneration
        let modeAtRead = movieMode
        let descriptor = try? await camera.remoteFocusMode()
        guard generation == focusModeRefreshGeneration, modeAtRead == movieMode, !stopRequested else { return }
        let previousLabel = focusModeDescriptor.flatMap { RemoteFocusMode.label(property: $0.property, value: $0.current) }
        let nextLabel = descriptor.flatMap { RemoteFocusMode.label(property: $0.property, value: $0.current) }
        // Android keys focus invalidation to the displayed mode, not its wire encoding.
        if previousLabel != nextLabel { invalidateFocusFrame() }
        focusModeDescriptor = descriptor
        state.focus.manual = descriptor.map {
            RemoteFocusMode.manual(property: $0.property, value: $0.current)
        } ?? false
    }

    func setHDLiveView(_ enabled: Bool) {
        guard hdLiveView != enabled, !stopRequested else { return }
        hdLiveView = enabled
        clearFrameOnNextSession = true
        // Cooperatively finish the command on the wire. EndLiveView precedes
        // the new size write/start, without releasing the page's remote gate.
        restartLiveView = true
    }

    func setFrameAnalysis(histogram: Bool, zebra: Bool, waveform: RemoteWaveformMode = .off, falseColor: Bool = false, histogramRGB: Bool = false) {
        histogramEnabled = histogram
        zebraEnabled = zebra
        waveformMode = waveform
        falseColorEnabled = falseColor
        histogramRGBEnabled = histogramRGB
        if !histogram { frameHistogram = nil; frameHistogramRGB = nil }
        if !zebra { frameZebraMask = nil }
        if waveform == .off { frameWaveform = nil }
        if !falseColor { frameFalseColorPixels = nil; frameFalseColorSize = .zero }
        Task { [weak self] in await self?.applyFrameAnalysis() }
    }

    private func applyFrameAnalysis() async {
        await frameDecoder.setAnalysis(histogram: histogramEnabled, zebra: zebraEnabled,
                                       waveform: waveformMode != .off, waveformRGB: waveformMode == .rgb,
                                       falseColor: falseColorEnabled, histogramRGB: histogramRGBEnabled)
    }

    private var exposureMeterBusy: Bool {
        state.capture == .capturing || recordingBusy || autoISOBusy || halfPressHeld ||
            halfPressTask != nil || tapFocusTask != nil || !pendingSets.isEmpty
    }

    private func waitForMeterProbe(generation: UInt64) async -> Bool {
        while exposureMeterBusy {
            guard !Task.isCancelled, generation == exposureMeterGeneration, !stopRequested else { return false }
            do { try await waitForPolling(for: .milliseconds(250)) } catch { return false }
        }
        return !Task.isCancelled && generation == exposureMeterGeneration && !stopRequested
    }

    func setExposureMeterVisible(_ visible: Bool) {
        exposureMeterEnabled = visible
        restartExposureMeter()
    }

    func setExposureMeterForeground(_ active: Bool) {
        guard exposureMeterForeground != active else { return }
        exposureMeterForeground = active
        restartExposureMeter()
    }

    private func restartExposureMeter() {
        exposureMeterGeneration &+= 1
        let generation = exposureMeterGeneration
        exposureMeterTask?.cancel()
        clearExposureMeterSample()
        guard exposureMeterEnabled, exposureMeterForeground, initialLoaded, state.liveViewStable,
              !stopRequested else { return }
        exposureMeterTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == exposureMeterGeneration { clearExposureMeterSample() }
            }
            var descriptor: RemotePropertyDescriptor?
            for _ in 0..<3 {
                guard !Task.isCancelled, generation == exposureMeterGeneration, !stopRequested else { return }
                guard await waitForMeterProbe(generation: generation) else { return }
                descriptor = try? await camera.remoteProperty(.nikonLightMeter)
                guard !Task.isCancelled, generation == exposureMeterGeneration, !stopRequested else { return }
                if descriptor != nil { break }
                do { try await waitForPolling(for: .milliseconds(700)) } catch { return }
            }
            if descriptor == nil || descriptor?.dataType != 1 || descriptor?.writable == true {
                guard !Task.isCancelled, generation == exposureMeterGeneration, !stopRequested else { return }
                guard await waitForMeterProbe(generation: generation) else { return }
                descriptor = try? await camera.remoteProperty(.nikonExposureIndicate)
            }
            guard !Task.isCancelled, generation == exposureMeterGeneration, !stopRequested,
                  let descriptor, descriptor.dataType == 1, !descriptor.writable else { return }
            var failures = 0
            while !Task.isCancelled && generation == exposureMeterGeneration && !stopRequested {
                if exposureMeterBusy {
                    if let ev = exposureMeterEV { publishExposureMeter(ev, started: .now, generation: generation) }
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                }
                let started = ContinuousClock.now
                let value: RemotePropertyDescriptor?
                do { value = try await camera.refreshRemoteProperty(descriptor) }
                catch { return }
                guard !Task.isCancelled, generation == exposureMeterGeneration, !stopRequested else { return }
                failures = value == nil ? failures + 1 : 0
                if let value,
                   let ev = RemoteExposureMeter.ev(property: value.property.rawValue, dataType: value.dataType,
                                                   writable: value.writable, current: Int64(bitPattern: value.current)),
                   started.duration(to: .now) < .milliseconds(1500), !exposureMeterBusy {
                    publishExposureMeter(ev, started: started, generation: generation)
                }
                if failures >= 3 { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func clearExposureMeterSample() {
        exposureMeterExpiryTask?.cancel()
        exposureMeterExpiryTask = nil
        exposureMeterEV = nil
    }

    private func publishExposureMeter(_ ev: Float, started: ContinuousClock.Instant, generation: UInt64) {
        exposureMeterExpiryTask?.cancel()
        exposureMeterEV = ev
        exposureMeterExpiryTask = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: started.advanced(by: .seconds(3))) }
            catch { return }
            guard let self, !Task.isCancelled, generation == exposureMeterGeneration else { return }
            exposureMeterEV = nil
            exposureMeterExpiryTask = nil
        }
    }

    /// Android clears the displayed frame on a new HD session, but retains it
    /// across acquisition retries, movie compatibility and computer-control restarts.
    private func clearDisplayedFrame() {
        frameImage = nil
        frameData = nil
        frameMetadata = nil
        frameReceivedAtUptime = 0
        frameHistogram = nil
        frameHistogramRGB = nil
        frameWaveform = nil
        frameFalseColorPixels = nil
        frameFalseColorSize = .zero
        frameZebraMask = nil
    }

    private func invalidateFocusFrame() {
        focusValidAfterUptime = ProcessInfo.processInfo.systemUptime
    }

    private func scheduleFocusExpiry() {
        focusFrameExpired = ProcessInfo.processInfo.systemUptime - frameReceivedAtUptime >= 0.5
        guard !focusFrameExpired, focusExpiryTask == nil else { return }
        // One timer follows the latest arrival. Continuous frames do not create
        // a new task each time; a quiet stream still publishes expiry at 500ms.
        focusExpiryTask = Task { [weak self] in
            guard let self else { return }
            defer { focusExpiryTask = nil }
            while !Task.isCancelled && !stopRequested {
                let remaining = frameReceivedAtUptime + 0.5 - ProcessInfo.processInfo.systemUptime
                if remaining <= 0 { focusFrameExpired = true; return }
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            }
        }
    }

    private func acceptDecodedFrame(_ decoded: RemoteDecodedFrame) {
        guard !stopRequested, decoded.generation == frameDecodeGeneration else { return }
        frameData = decoded.jpeg
        frameImage = decoded.image
        frameMetadata = decoded.metadata
        frameReceivedAtUptime = decoded.receivedAtUptime
        scheduleFocusExpiry()
        frameHistogram = decoded.histogram
        frameHistogramRGB = decoded.histogramRGB
        frameWaveform = decoded.waveform
        frameFalseColorPixels = decoded.falseColorPixels
        frameFalseColorSize = CGSize(width: decoded.falseColorWidth, height: decoded.falseColorHeight)
        frameZebraMask = decoded.zebraMask
        if focusDiagnostic.running {
            let packet = RemoteLiveViewPacket(bytes: decoded.rawBytes, jpegOffset: decoded.jpegOffset,
                                               operation: decoded.operation,
                                               receivedAtUptime: decoded.receivedAtUptime)
            let context = "movie=\(movieMode) rec=\(String(describing: state.capture)) af=\(focusModeDescriptor.map { String($0.current) } ?? "unknown")"
            focusDiagnostic.sample(packet: packet, metadata: decoded.metadata, context: context)
            focusDiagnosticReport = focusDiagnostic.report()
            if !focusDiagnostic.running { focusDiagnosticRunning = false }
        }
        state = state.applying(.frameReceived(fps: decoded.fps))
        if initialLoaded { usageMeter.markReady() }
        if localRecordingPhase == .recording {
            localRecorder?.append(image: decoded.image, receivedAtUptime: decoded.receivedAtUptime,
                                  desqueeze: recordingDesqueeze)
        }
    }

    private var localRecordingToolVisible = true

    /// A hidden portrait entry closes recording; the landscape fixed recorder
    /// keeps an existing recording alive. Both paths disallow starting a new
    /// recording, including a microphone permission reply arriving later.
    func setLocalRecordingToolVisible(_ visible: Bool, fixedRecorder: Bool) {
        localRecordingToolVisible = visible
        guard !visible else { return }
        if localRecordingPhase == .idle || localRecordingPhase == .saved {
            localRecordingTask?.cancel()
            localRecordingTask = nil
        }
        if !fixedRecorder { stopLocalRecording() }
    }

    func startLocalRecording() {
        guard premiumAccess.isPro else {
            showLocalRecordingHint(AppLocalized.resource("remote_rec_pro_only"), durationNanoseconds: 2_500_000_000); return
        }
        guard localRecordingToolVisible else { return }
        guard localRecordingPhase == .idle || localRecordingPhase == .saved,
              localRecorder == nil, frameImage != nil else {
            if frameImage == nil { showLocalRecordingHint(AppLocalized.resource("remote_rec_start_failed")) }
            return
        }
        localRecordingTask?.cancel()
        localRecordingTask = Task { [weak self] in
            guard let self else { return }
            let permission = await microphonePermission()
            guard !Task.isCancelled, !stopRequested, localRecordingToolVisible else { return }
            guard premiumAccess.isPro else {
                showLocalRecordingHint(AppLocalized.resource("remote_rec_pro_only"), durationNanoseconds: 2_500_000_000)
                localRecordingTask = nil
                return
            }
            if !permission {
                showLocalRecordingHint(AppLocalized.resource("remote_rec_no_audio"))
            }
            guard let image = frameImage else {
                showLocalRecordingHint(AppLocalized.resource("remote_rec_start_failed"))
                localRecordingTask = nil
                return
            }
            startLocalRecordingResolved(size: image.size, withAudio: permission)
            localRecordingTask = nil
        }
    }

    func toggleLocalRecordingPause() {
        switch localRecordingPhase {
        case .recording:
            localRecorder?.pause()
            localRecordingPhase = .paused
        case .paused:
            guard premiumAccess.isPro else { stopLocalRecording(); return }
            localRecorder?.resume()
            localRecordingPhase = .recording
        default: break
        }
    }

    func markMonitorHintHostInactive() { recordingHintHostActive = false }

    func stopLocalRecording() {
        guard localRecordingPhase == .recording || localRecordingPhase == .paused,
              let recorder = localRecorder else { return }
        localRecorder = nil
        localRecordingTimerTask?.cancel()
        localRecordingTimerTask = nil
        localRecordingSeconds = 0
        localRecordingPhase = .finalizing
        localRecordingTask = Task { [weak self] in
            let url = await recorder.stop()
            guard let self else { return }
            localRecordingTask = nil
            if url != nil {
                haptics.success()
                localRecordingPhase = .saved
                localRecordingSavedTask?.cancel()
                localRecordingSavedTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(1800))
                    guard let self, localRecordingPhase == .saved else { return }
                    localRecordingPhase = .idle
                }
            } else {
                haptics.failure()
                localRecordingPhase = .idle
                let message = AppLocalized.resource("cd_remote_rec_toast_failed")
                if !recordingHintHostActive { onRecordingSaveFailure(message) }
                else { showLocalRecordingHint(message) }
            }
        }
    }

    private func startLocalRecordingResolved(size: CGSize, withAudio: Bool) {
        guard localRecordingToolVisible, localRecorder == nil,
              localRecordingPhase != .finalizing else { return }
        let id = UUID()
        localRecordingID = id
        let onEncodingFailure: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, localRecordingID == id else { return }
                stopLocalRecording()
            }
        }
        let preferred = RemoteViewfinderRecorder.outputURL(preferredDirectory: recordingDirectory)
        var recorder = makeLocalRecorder(.init(outputURL: preferred, sourceSize: size, withAudio: withAudio,
                                                desqueeze: recordingDesqueeze, onEncodingFailure: onEncodingFailure))
        var started = recorder.start()
        if !started, recordingDirectory != nil {
            recorder = makeLocalRecorder(.init(
                outputURL: RemoteViewfinderRecorder.outputURL(preferredDirectory: nil),
                sourceSize: size,
                withAudio: withAudio, desqueeze: recordingDesqueeze, onEncodingFailure: onEncodingFailure
            ))
            started = recorder.start()
        }
        guard started else {
            localRecordingPhase = .idle
            showLocalRecordingHint(AppLocalized.resource("remote_rec_start_failed"))
            return
        }
        localRecordingSavedTask?.cancel()
        localRecordingPhase = .recording
        localRecordingSeconds = 0
        localRecorder = recorder
        localRecordingTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if localRecordingPhase == .recording { localRecordingSeconds += 1 }
                if localRecordingPhase != .recording && localRecordingPhase != .paused { return }
            }
        }
    }

    private func microphonePermission() async -> Bool {
        if let requestMicrophonePermission { return await requestMicrophonePermission() }
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                session.requestRecordPermission { continuation.resume(returning: $0) }
            }
        @unknown default: return false
        }
    }

    private func showLocalRecordingHint(_ message: String, durationNanoseconds: UInt64 = 3_000_000_000) {
        showMonitorHint(message, source: .localRecording, durationNanoseconds: durationNanoseconds)
    }

    private func readExposure(_ field: RemoteExposureField, movie: Bool) async -> RemotePropertyDescriptor? {
        var readable: RemotePropertyDescriptor?
        for property in RemoteExposureParameters.compatibleProperties(for: field, movie: movie) {
            guard !stopRequested else { return nil }
            guard let descriptor = try? await camera.remoteProperty(property) else { continue }
            if readable == nil { readable = descriptor }
            if descriptor.writable && !descriptor.values.isEmpty { return descriptor }
        }
        return readable
    }

    private func loadExposure(movie: Bool, preservingPending: Bool = false) async {
        var loaded: [RemoteExposureField: RemotePropertyDescriptor] = [:]
        for field in [RemoteExposureField.exposureCompensation, .iso, .aperture, .shutter] {
            if preservingPending, let current = exposureDescriptors[field],
               pendingSets[RemoteExposureParameters.canonical(current.property)] != nil {
                loaded[field] = current
                continue
            }
            if let descriptor = await readExposure(field, movie: movie) { loaded[field] = descriptor }
        }
        guard !stopRequested else { return }
        exposureDescriptors = loaded
        exposureDescriptorCache[movie] = loaded
        await refreshAutoISO()
    }

    private func refreshAutoISO() async {
        let movie = movieMode
        let preferred = RemoteExposureParameters.autoISOProperties(movie: movie)
        var candidates = preferred
        if autoISOMovieMode == movie, let previous = autoISODescriptor?.property, preferred.contains(previous) {
            candidates = [previous] + preferred.filter { $0 != previous }
        }
        var found: RemotePropertyDescriptor?
        for property in candidates {
            guard !stopRequested else { return }
            if let descriptor = try? await camera.remoteProperty(property), descriptor.isBinaryToggle {
                found = descriptor
                break
            }
        }
        guard !stopRequested, movieMode == movie else { return }
        let previousMode = autoISOMovieMode
        let previousKey = autoISODescriptor.map { ($0.property, $0.current != 0) }
        autoISODescriptor = found
        autoISOMovieMode = movie
        if autoISOEnabled {
            if let next = try? await camera.remoteProperty(.nikonISOControlSensitivity) { effectiveISO = next }
        }
        else { effectiveISO = nil }
        if previousMode != movie || previousKey?.0 != found?.property || previousKey?.1 != found.map({ $0.current != 0 }) {
            updateEffectiveISOPolling()
        }
    }

    var autoISOEnabled: Bool { autoISODescriptor.map { $0.current != 0 } ?? false }

    func setLevelVisible(_ visible: Bool) {
        guard visible != levelVisible, !stopRequested else { return }
        levelVisible = visible
        levelGeneration &+= 1
        let generation = levelGeneration
        let previous = levelTask
        levelRoll = nil
        levelPitch = nil
        guard visible else { return }
        levelTask = Task { [weak self] in
            // Finish an in-flight PTP transaction before replacing its owner.
            await previous?.value
            guard let self else { return }
            @MainActor func active() -> Bool { !stopRequested && levelVisible && levelGeneration == generation }
            while active() && !initialLoaded {
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard active() else { return }
            var param: RemotePropertyDescriptor?
            var failures = 0
            var fallbackUnavailable = false
            var wasHeader = false
            while active() {
                let age = ProcessInfo.processInfo.systemUptime - frameReceivedAtUptime
                if let attitude = frameMetadata?.attitude, age >= 0, age <= 1.5 {
                    levelRoll = Double(floor(attitude.roll * 10 + 0.5) / 10)
                    levelPitch = Double(floor(attitude.pitch * 10 + 0.5) / 10)
                    wasHeader = true
                } else {
                    levelPitch = nil
                    if wasHeader { levelRoll = nil }
                    wasHeader = false
                    if !fallbackUnavailable {
                        if let previous = param { param = try? await camera.refreshRemoteProperty(previous) }
                        else { param = try? await camera.remoteProperty(.angleLevel) }
                        guard active() else { return }
                        if let roll = param?.angleLevelRoll {
                            levelRoll = Double(floor(Float(roll) * 10 + 0.5) / 10)
                            failures = 0
                        } else {
                            failures += 1
                            if failures >= 3 {
                                levelRoll = nil
                                fallbackUnavailable = true
                            }
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// One feedback pulse per camera detent, matching RemoteScreen's
    /// onValueStep callback. The eventual write is coalesced by the model.
    func detentFeedback() {
        haptics.tick()
    }

    private func updateEffectiveISOPolling() {
        effectiveISOGeneration &+= 1
        let generation = effectiveISOGeneration
        let previous = effectiveISOTask
        guard !stopRequested, autoISOEnabled, state.liveViewStable else { return }
        effectiveISOTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            @MainActor func active() -> Bool {
                !stopRequested && autoISOEnabled && state.liveViewStable && generation == effectiveISOGeneration
            }
            var current = effectiveISO
            var attempts = 0
            while active() && current == nil && attempts < 8 {
                current = try? await camera.remoteProperty(.nikonISOControlSensitivity)
                attempts += 1
                if current == nil { try? await waitForPolling(for: .milliseconds(150)) }
            }
            guard active(), var descriptor = current else { return }
            effectiveISO = descriptor
            while active() {
                if let next = try? await camera.refreshRemoteProperty(descriptor), active() {
                    descriptor = next
                    effectiveISO = next
                }
                try? await waitForPolling(for: .milliseconds(500))
            }
        }
    }

    func setAutoISO(_ enabled: Bool) {
        guard !stopRequested, !autoISOBusy, let descriptor = autoISODescriptor, descriptor.writable,
              (descriptor.current != 0) != enabled else { return }
        let requestedMovie = movieMode
        autoISOBusy = true
        var optimistic = descriptor
        optimistic.current = descriptor.values.first(where: { ($0 != 0) == enabled }) ?? (enabled ? 1 : 0)
        autoISODescriptor = optimistic
        effectiveISO = nil
        updateEffectiveISOPolling()
        haptics.tick()
        autoISOCommandTask = Task { [weak self] in
            guard let self else { return }
            defer { autoISOBusy = false; autoISOCommandTask = nil }
            var candidates = [descriptor]
            if requestedMovie {
                for property in RemoteExposureParameters.autoISOProperties(movie: true) where property != descriptor.property {
                    guard !stopRequested else { return }
                    if let candidate = try? await camera.remoteProperty(property), candidate.isBinaryToggle {
                        candidates.append(candidate)
                    }
                }
            }
            var confirmed: RemotePropertyDescriptor?
            for candidate in candidates {
                guard !stopRequested else { return }
                if (candidate.current != 0) == enabled { confirmed = candidate; break }
                let target = candidate.values.first(where: { ($0 != 0) == enabled }) ?? (enabled ? 1 : 0)
                do {
                    let result = try await camera.setRemotePropertyVerified(candidate, value: target) { [weak self] in
                        await self?.remoteCommandsAllowed() ?? false
                    }
                    if candidate.property == descriptor.property { autoISODescriptor = result.actual ?? descriptor }
                    if result.confirmed { confirmed = result.actual; break }
                } catch is CancellationError { return }
                catch {
                    if Self.isTransportFailure(error) { notifyTransportLost(); return }
                    if candidate.property == descriptor.property { autoISODescriptor = descriptor }
                }
            }
            guard !stopRequested else { return }
            if let confirmed {
                autoISODescriptor = confirmed
                autoISOMovieMode = requestedMovie
            }
            await refreshAutoISO()
            if movieMode { exposureDescriptors[.iso] = await readExposure(.iso, movie: true) }
        }
    }

    var cameraToolWritesAllowed: Bool {
        !stopRequested && initialLoaded && state.capture != .capturing && !recordingBusy &&
            !halfPressHeld && halfPressTask == nil && tapFocusTask == nil
    }

    func openCameraTool(_ tool: RemoteCameraTool) {
        guard !stopRequested, !cameraToolWriting else {
            showInteractionHint(AppLocalized.resource("remote_camera_tool_unavailable"))
            return
        }
        if let panel = cameraToolPanel, panel.tool == tool {
            panel.requestClose()
            return
        }
        dismissCameraTool()
        let id = UUID()
        let panel = RemoteCameraToolController(id: id, camera: camera, tool: tool, movie: movieMode,
            isCurrent: { [weak self] in self.map { !$0.stopRequested } ?? false },
            currentMovie: { [weak self] in self?.movieMode ?? false },
            canWrite: { [weak self] in self?.cameraToolWritesAllowed ?? false },
            beforeWrite: { [weak self] in
                guard let self else { return false }
                if tool != .whiteBalance && state.focus.tracking {
                    do {
                        let response = try await camera.endSubjectTrackingForTool()
                        if let response, ![PTPConstants.responseOK, PTPConstants.operationNotSupported, 0xA004].contains(response) {
                            return false
                        }
                        state.focus.tracking = false
                        confirmedFocusMarker = nil
                    } catch { return false }
                }
                return true
            }, onApplied: { [weak self] in
                guard let self, tool != .whiteBalance else { return }
                invalidateFocusFrame()
                confirmedFocusMarker = nil
                state.focus.phase = .idle
                state.focus.point = nil
                state.focus.tracking = false
                await refreshFocusMode()
            }, onUnavailable: { [weak self] in
                self?.showInteractionHint(AppLocalized.resource("remote_camera_tool_unavailable"))
            }, onDismiss: { [weak self] in self?.retireCameraTool(id) },
            onWriteBusyChanged: { [weak self] busy in
                guard let self else { return false }
                if busy && self.cameraToolWriting { return false }
                self.cameraToolWriting = busy
                return true
            })
        cameraToolPanel = panel
        panel.start()
    }

    func dismissCameraTool() { cameraToolPanel?.dismiss() }

    var computerControlToggleAllowed: Bool {
        !stopRequested && frameTask != nil && !computerControlBusy && !cameraBusy
    }

    /// Android's configurable PC control tool owns the whole Live View
    /// transaction while SetControlMode runs. Stop the old stream first, keep
    /// the current frame visible, then rebuild the stream after the mode change.
    func toggleComputerControl() {
        guard computerControlToggleAllowed else { return }
        setComputerControl(!computerControlEnabled)
    }

    /// Hiding the tool uses the same explicit setter as Android, independently
    /// of the button's capture/recording gate.
    func setComputerControl(_ enabled: Bool) {
        guard !stopRequested, frameTask != nil, !computerControlBusy else { return }
        computerControlBusy = true
        computerControlLog = ""
        computerControlTask = Task { [weak self] in
            guard let self else { return }
            var paused = false
            defer {
                computerControlBusy = false
                computerControlTask = nil
                if paused && !stopRequested { resumeLiveViewAfterMovieTransition(adoptStarted: false) }
            }
            do {
                await pauseLiveViewForMovieTransition()
                paused = true
                guard !stopRequested else { return }
                await camera.endLiveView()
                guard !stopRequested else { return }
                let response = try await camera.setRemoteDiagnosticControlMode(enabled)
                computerControlLog = response == PTPConstants.responseOK
                    ? "ComputerControl \(enabled ? "enabled" : "disabled")"
                    : String(format: "!! ComputerControl %@ resp=0x%04X", enabled ? "enable" : "disable", response)
                guard !stopRequested, response == PTPConstants.responseOK else { return }
                computerControlEnabled = enabled
            } catch is CancellationError {
            } catch {
                computerControlLog = "!! ComputerControl \(enabled ? "enable" : "disable") failed=\(String(describing: type(of: error))): \(Self.message(for: error))"
                if Self.isTransportFailure(error) { notifyTransportLost() }
            }
        }
    }

    private func retireCameraTool(_ id: UUID) {
        guard let panel = cameraToolPanel, panel.id == id else { return }
        cameraToolPanel = nil
        retiringCameraTools[id] = Task { [weak self] in
            await panel.drain()
            self?.retiringCameraTools[id] = nil
        }
    }

    private func remoteCommandsAllowed() -> Bool { !stopRequested }

    /// Android stepParam applies a crossed-detent delta to the latest camera
    /// value, including external changes received during the same gesture.
    func stepExposure(_ field: RemoteExposureField, delta: Int) {
        guard let descriptor = exposureDescriptors[field], descriptor.writable,
              !descriptor.values.isEmpty else { return }
        // stepParam receives the logical exposure key; the descriptor keeps
        // the camera's actual property code for writing and display.
        let from = RemoteExposureParameters.anchorIndex(for: RemoteExposureParameters.canonical(descriptor.property),
            values: descriptor.values, current: descriptor.current)
        let next = min(descriptor.values.count - 1, max(0, from + delta))
        setExposure(field, value: descriptor.values[next], immediate: false)
    }

    func setExposure(_ field: RemoteExposureField, value: UInt64, feedback: Bool = true, immediate: Bool = true) {
        guard !stopRequested, let descriptor = exposureDescriptors[field], descriptor.writable,
              descriptor.current != value else { return }
        let property = RemoteExposureParameters.canonical(descriptor.property)
        let requestedMovie = movieMode
        let generation = (pendingSetGenerations[property] ?? 0) &+ 1
        pendingSetGenerations[property] = generation
        let previous = pendingSets[property]
        var optimistic = descriptor
        optimistic.current = value
        exposureDescriptors[field] = optimistic
        if feedback { haptics.tick() }
        pendingSets[property] = Task { [weak self] in
            // Complete the old wire transaction, but discard its stale result.
            // A replacement's 160 ms debounce runs concurrently with that drain.
            let deadline = ContinuousClock.now.advanced(by: immediate ? .zero : .milliseconds(160))
            await previous?.value
            if ContinuousClock.now < deadline { try? await Task.sleep(until: deadline) }
            guard let self else { return }
            @MainActor func active() -> Bool {
                !stopRequested && pendingSetGenerations[property] == generation
            }
            defer { if pendingSetGenerations[property] == generation { pendingSets[property] = nil } }
            guard active() else { return }
            do {
                let result = try await camera.setRemotePropertyVerified(descriptor, value: value) { [weak self] in
                    await self?.isExposureWriteCurrent(property, generation: generation) ?? false
                }
                guard active(), requestedMovie == movieMode else { return }
                if let actual = result.actual { exposureDescriptors[field] = actual }
                if !result.confirmed {
                    let refreshed = await readExposure(field, movie: requestedMovie)
                    if active(), let refreshed { exposureDescriptors[field] = refreshed }
                }
            } catch is CancellationError { }
            catch {
                guard active() else { return }
                if Self.isTransportFailure(error) { notifyTransportLost(); return }
                let refreshed = await readExposure(field, movie: requestedMovie)
                if active(), requestedMovie == movieMode, let refreshed { exposureDescriptors[field] = refreshed }
            }
        }
    }

    private func isExposureWriteCurrent(_ property: RemoteProperty, generation: Int) -> Bool {
        !stopRequested && pendingSetGenerations[property] == generation
    }

    /// Cancel only the idle timer on exit; callers retain ownership of any
    /// in-flight PTP request and drain it before releasing the remote gate.
    private func waitForPolling(for duration: Duration) async throws {
        guard !stopRequested else { throw CancellationError() }
        let id = UUID()
        let delay = Task { try await Task.sleep(for: duration) }
        pollingDelays[id] = delay
        defer { pollingDelays.removeValue(forKey: id) }
        try await withTaskCancellationHandler {
            try await delay.value
        } onCancel: {
            delay.cancel()
        }
    }

    func stop() {
        focusExpiryTask?.cancel()
        focusExpiryTask = nil
        markMonitorHintHostInactive()
        stopFocusDiagnostic(reason: "left-monitor")
        usageMeter.stop()
        disposed = true
        stopRequested = true
        for delay in pollingDelays.values { delay.cancel() }
        dismissCameraTool()
        // A USB start response can arrive after the page has begun leaving but
        // before local state changes to `.recording`. Remember the wire command
        // so teardown cannot leave the camera recording invisibly.
        stopMovieOnExit = state.capture == .recording || state.capture == .stopping ||
            recordingCommandInFlight == .start
        effectiveISOGeneration &+= 1
        halfPressHeld = false
        halfPressVisualActive = false
        levelGeneration &+= 1
        levelVisible = false
        exposureMeterGeneration &+= 1
        exposureMeterTask?.cancel()
        clearExposureMeterSample()
        levelRoll = nil
        levelPitch = nil
        focusHideTask?.cancel()
        recordingOperations.invalidate()
        recordingTimerTask?.cancel()
        recordingTimerTask = nil
        monitorHintTask?.cancel()
        monitorHintTask = nil
        monitorHint.visible = false
        recordingSeconds = 0
        state = state.applying(.cancelled)
        clearDisplayedFrame()
        monitorStorageFreeBytes = [:]
        monitorStorageSlotCount = 0
        monitorStorageSlotByID = [:]
        storageGeneration &+= 1
        storageTask?.cancel()
        storageTask = nil
        frameReceivedAtUptime = 0
        frameHistogram = nil
        frameZebraMask = nil
        frameDecodeGeneration &+= 1
        lastFrameAt = nil
        state.focus = .init()
        confirmedFocusMarker = nil
        focusAreaPoint = RemoteFocusPoint(x: 0.5, y: 0.5)
    }

    func startFocusDiagnostic(description: String) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        focusDiagnostic.start(nowMs: Int64((ProcessInfo.processInfo.systemUptime * 1000).rounded()),
                              description: "date=\(ISO8601DateFormatter().string(from: Date())) app=\(version)(\(build)) \(description)")
        focusDiagnosticRunning = true
        focusDiagnosticReport = focusDiagnostic.report()
    }

    func stopFocusDiagnostic(reason: String = "stopped") {
        focusDiagnostic.stop(reason: reason)
        focusDiagnosticRunning = false
        focusDiagnosticReport = focusDiagnostic.report()
    }

    func markFocusDiagnostic(_ text: String) {
        focusDiagnostic.mark(nowMs: Int64((ProcessInfo.processInfo.systemUptime * 1000).rounded()), text: text)
        focusDiagnosticReport = focusDiagnostic.report()
    }

    func displayFocusDiagnostic(_ state: String) {
        focusDiagnostic.display(state)
        focusDiagnosticReport = focusDiagnostic.report()
    }

    func runLegacyVideoDiagnostic() {
        runVideoDiagnostic { camera in try await camera.probeLegacyVideoTime() }
    }

    func runMovieFormatDiagnostic() {
        runVideoDiagnostic { camera in try await camera.probeMovieFormat() }
    }

    private func runVideoDiagnostic(_ operation: @escaping (any RemoteCameraControlling) async throws -> String) {
        guard !videoDiagnosticBusy, state.session == .ready, !cameraBusy else { return }
        videoDiagnosticBusy = true
        videoDiagnosticLog = ""
        videoDiagnosticTask = Task { [weak self] in
            guard let self else { return }
            defer {
                videoDiagnosticBusy = false
                videoDiagnosticTask = nil
            }
            do {
                videoDiagnosticLog = try await operation(camera)
            } catch is CancellationError {
                videoDiagnosticLog = "diagnostic cancelled"
            } catch {
                videoDiagnosticLog = "diagnostic error: \(Self.message(for: error))"
            }
        }
    }

    /// Waits for any active PTP operations to finish their normal protocol
    /// teardown before the photo list starts catalog work again.
    func stopAndWait() async {
        guard !cleanupComplete else { return }
        if let cleanupTask { await cleanupTask.value; return }
        let task = Task { [self] in await performStopAndWait() }
        cleanupTask = task
        await task.value
        cleanupComplete = true
        cleanupTask = nil
    }

    private func performStopAndWait() async {
        if localRecordingPhase == .recording || localRecordingPhase == .paused { stopLocalRecording() }
        stop()
        let frame = frameTask
        let mode = modeTask
        let recording = recordingCommandTask
        await halfPressTask?.value
        await tapFocusTask?.value
        await batteryTask?.value
        batteryTask = nil
        await storageTask?.value
        storageTask = nil
        await movieFormatTask?.value
        movieFormatTask = nil
        await displayDetailsTask?.value
        displayDetailsTask = nil
        await videoDiagnosticTask?.value
        videoDiagnosticTask = nil
        await effectiveISOTask?.value
        effectiveISOTask = nil
        await autoISOCommandTask?.value
        for task in pendingSets.values { await task.value }
        pendingSets.removeAll()
        for task in retiringCameraTools.values { await task.value }
        retiringCameraTools.removeAll()
        await levelTask?.value
        levelTask = nil
        await frame?.value
        await frameDecoder.reset(generation: frameDecodeGeneration)
        await frameDecoder.waitUntilIdle()
        await mode?.value
        await recording?.value
        // A late SetControlMode success must be accounted for before returning
        // the camera to the photo list. Do not cancel a command on the wire.
        await computerControlTask?.value
        await localRecordingTask?.value
        localRecordingTask = nil
        await captureTask?.value
        captureTask = nil
        frameTask = nil
        modeTask = nil
        recordingCommandTask = nil
        await movieCleanupTask?.value
        movieCleanupTask = nil
        if stopMovieOnExit { _ = try? await camera.endMovieRecording() }
        await releaseMovieSessionToStandby(resumeLiveView: false, releasingComputerControl: true)
        computerControlEnabled = false
        computerControlBusy = false
        await camera.setRemoteActive(false)
    }

    /// Starts the Android two-stage shutter AF. The initial tick is emitted
    /// when the half-press is accepted; the second tick only arrives while the
    /// finger is still held when AF actually locks.
    func beginHalfPress() {
        guard frameTask != nil,
              !state.focus.manual, !halfPressHeld, halfPressTask == nil, tapFocusTask == nil,
              !stopRequested, !cameraToolWriting else { return }
        halfPressHeld = true
        halfPressVisualActive = true
        focusHideTask?.cancel()
        confirmedFocusMarker = nil
        state.focus.tracking = false
        state = state.applying(.focusRequested(focusAreaPoint))
        let requestedPoint = focusAreaPoint
        haptics.tick()
        halfPressTask = Task { [weak self] in
            guard let self else { return }
            defer { halfPressTask = nil }
            do {
                let result = try await camera.halfPressFocus()
                guard !Task.isCancelled, !stopRequested else { return }
                guard !result.timedOut, result.responseCode == PTPConstants.responseOK else { return }
                setConfirmedFocusMarker(at: requestedPoint, subjectTracking: false)
                guard halfPressHeld else { return }
                haptics.tick()
                state = state.applying(.focusLocked)
            } catch is CancellationError {
            } catch {
                if Self.isTransportFailure(error) { notifyTransportLost() }
            }
        }
    }

    /// Releases the two-stage shutter. A long press only fires after the AF
    /// transaction has reached its terminal result; moving off the button
    /// cancels the visual/haptic completion without sending a late tick.
    func endHalfPress(fire: Bool) {
        halfPressHeld = false
        halfPressVisualActive = false
        state.focus.phase = .idle
        state.focus.point = nil
        guard fire, !stopRequested else { return }
        // Set shutter/record busy synchronously; those tasks wait for the AF
        // transaction before sending their command and starting confirmation.
        let pendingFocus = halfPressTask ?? tapFocusTask
        if movieMode { toggleRecording(waitForFocus: pendingFocus) }
        else { capture(waitForFocus: pendingFocus) }
    }

    func capture(waitForFocus pendingFocus: Task<Void, Never>? = nil) {
        guard frameTask != nil, state.capture == .idle, !movieMode, !stopRequested,
              !cameraToolWriting else { return }
        state = state.applying(.captureRequested)
        captureTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if !stopRequested { state = state.applying(.captureConfirmed) }
                captureTask = nil
            }
            // Android starts the twelve-second confirmation window only after
            // the pending AF transaction has reached its terminal response.
            await pendingFocus?.value
            guard !stopRequested else { return }
            captureObjectAdded = false
            let deadline = ContinuousClock.now + .seconds(12)
            haptics.longPress()
            do {
                try await camera.capturePhoto()
                while !stopRequested && !captureObjectAdded && ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
            } catch {
                if Self.isTransportFailure(error) { notifyTransportLost() }
                // Android always releases the shutter after failure/timeout;
                // a negative capture response must not fail the LV session.
            }
        }
    }

    func toggleRecording(waitForFocus pendingFocus: Task<Void, Never>? = nil) {
        guard movieMode, frameTask != nil, !stopRequested, !cameraToolWriting else { return }
        let command: RemoteRecordingCommand
        if state.capture == .recording || state.capture == .stopping { command = .stop }
        else if state.capture == .idle { command = .start }
        else { return }
        guard let token = recordingOperations.begin(command) else { return }
        recordingCommandInFlight = command

        recordingCommandTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if recordingCommandInFlight == command { recordingCommandInFlight = nil }
                // An old command must not release a newer page's busy owner.
                if recordingOperations.complete(token) { recordingCommandTask = nil }
            }
            do {
                await pendingFocus?.value
                guard !Task.isCancelled, !stopRequested else { return }
                haptics.longPress()
                switch command {
                case .start:
                    var result: RemoteMovieStartResult
                    var adopted = false
                    if camera.isUSB {
                        // RemoteScreen.shouldPrepareUsbMovieSessionForRecord:
                        // manual PC control already owns this session.
                        if !(await camera.hasRemoteControlMode()) {
                            await pauseLiveViewForMovieTransition()
                            _ = try await camera.refreshUSBRemoteSession()
                            guard try await camera.setRemoteControlMode(true) == PTPConstants.responseOK else {
                                throw PTPSessionError.responseCode(0xA004)
                            }
                            let size = RemotePropertyDescriptor(property: .liveViewImageSize, dataType: 0x0002,
                                                                writable: true, current: 3, values: [1, 2, 3])
                            try await camera.setRemoteProperty(size, value: 3)
                            try await camera.startLiveView()
                            adopted = true
                        }
                        result = try await camera.startPreparedUSBMovieRecording()
                        if adopted { resumeLiveViewAfterMovieTransition(adoptStarted: true) }
                    } else {
                        result = try await camera.startMovieRecording()
                        if result.needsLiveViewRestart {
                            await pauseLiveViewForMovieTransition()
                            try await camera.ensureMovieApplicationMode()
                            let size = RemotePropertyDescriptor(property: .liveViewImageSize, dataType: 0x0002,
                                                                writable: true, current: 2, values: [1, 2, 3])
                            try await camera.setRemoteProperty(size, value: hdLiveView ? 3 : 2)
                            try await camera.startLiveView()
                            adopted = true
                            result = try await camera.startMovieRecording()
                            resumeLiveViewAfterMovieTransition(adoptStarted: true)
                        }
                    }
                    guard !Task.isCancelled, recordingOperations.accepts(token) else { return }
                    if result.indicatesRecording { setRecording(true) }
                    else {
                        if adopted && liveViewPauseRequested {
                            resumeLiveViewAfterMovieTransition(adoptStarted: true)
                        }
                        await releaseMovieSessionToStandby(resumeLiveView: true)
                        showRecordingHint(.startFailed(result))
                    }
                case .stop:
                    // Android retains recording + its timer until EndMovieRec
                    // succeeds. A failed command cannot pretend the camera stopped.
                    lastStopCommandAt = .now
                    let completionBaseline = movieCompletionSequence
                    let waitsForCompletion = await camera.hasMovieApplicationMode()
                    let response = try await camera.endMovieRecording()
                    guard !Task.isCancelled, recordingOperations.accepts(token) else { return }
                    if response == PTPConstants.responseOK {
                        setRecording(false)
                        if waitsForCompletion {
                            await waitForMovieCompletion(after: completionBaseline)
                        }
                        await releaseMovieSessionToStandby(resumeLiveView: true)
                    }
                    else { showRecordingHint(.stopFailed(responseCode: response)) }
                }
            } catch is CancellationError {
                // Leaving cancels ownership; no hint or late recording state.
            } catch {
                guard !Task.isCancelled, recordingOperations.accepts(token) else { return }
                if Self.isTransportFailure(error) { notifyTransportLost(); return }
                if command == .start {
                    if liveViewPauseRequested { resumeLiveViewAfterMovieTransition(adoptStarted: false) }
                    await releaseMovieSessionToStandby(resumeLiveView: true)
                }
                // Failed EndMovie is not evidence of a stopped recording. Keep
                // application/control ownership until retry or completion event.
                showRecordingHint(command == .start ? .startFailed(nil) : .stopFailed())
            }
        }
    }

    private func pauseLiveViewForMovieTransition() async {
        guard !stopRequested else { return }
        // Do not reuse an acknowledgement from a previous transition.  A
        // second pause can arrive while the frame loop is still leaving the
        // prior adopted Live View; it must wait for this request to be seen.
        liveViewPaused = false
        liveViewPauseRequested = true
        restartLiveView = true
        frameDecodeGeneration &+= 1
        await frameDecoder.reset(generation: frameDecodeGeneration)
        state = state.applying(.frameLost)
        state.liveViewStable = false
        state.fps = 0
        updateEffectiveISOPolling()
        while !stopRequested && !liveViewPaused {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func resumeLiveViewAfterMovieTransition(adoptStarted: Bool) {
        invalidateFocusFrame()
        adoptStartedLiveView = adoptStarted
        liveViewPauseRequested = false
    }

    private func waitForMovieCompletion(after baseline: Int) async {
        let deadline = ContinuousClock.now + .seconds(8)
        while !stopRequested && movieCompletionSequence == baseline && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func scheduleMovieStandbyCleanup() {
        guard movieCleanupTask == nil, !stopRequested else { return }
        movieCleanupTask = Task { [weak self] in
            guard let self else { return }
            await releaseMovieSessionToStandby(resumeLiveView: true)
            movieCleanupTask = nil
        }
    }

    private func releaseMovieSessionToStandby(resumeLiveView: Bool, releasingComputerControl: Bool = false) async {
        guard !movieSessionReleaseInProgress else { return }
        movieSessionReleaseInProgress = true
        defer { movieSessionReleaseInProgress = false }
        let hasControl = await camera.hasRemoteControlMode()
        let hasApplication = await camera.hasMovieApplicationMode()
        if resumeLiveView && !releasingComputerControl {
            // Android only rebuilds the USB control session here. Wi-Fi
            // completion clears ApplicationMode in place, preserving LV and
            // any independently held manual PC-control mode.
            if !camera.isUSB || !hasControl {
                await camera.clearMovieApplicationMode(force: false)
                return
            }
            if await camera.hasRemoteDiagnosticControlMode() { return }
        } else if !releasingComputerControl, await camera.hasRemoteDiagnosticControlMode() {
            return
        }
        guard hasControl || hasApplication else { return }
        if resumeLiveView { await pauseLiveViewForMovieTransition() }
        else { await camera.endLiveView() }
        await camera.clearMovieApplicationMode(force: true)
        if hasControl {
            for attempt in 0..<3 {
                let response = try? await camera.setRemoteControlMode(false)
                if response == PTPConstants.responseOK { break }
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(300)) }
            }
        }
        // A failed release keeps LV stopped. The 600ms recovery poll above
        // tries another three-command batch; only confirmed release restarts.
        let controlStillHeld = await camera.hasRemoteControlMode()
        if resumeLiveView && !stopRequested && !controlStillHeld {
            resumeLiveViewAfterMovieTransition(adoptStarted: false)
        }
    }

    private func setRecording(_ recording: Bool) {
        let wasRecording = state.capture == .recording
        state = state.applying(recording ? .recordingStarted : .recordingStopped)
        guard wasRecording != recording else { return }
        recordingTimerTask?.cancel()
        recordingTimerTask = nil
        recordingSeconds = 0
        guard recording else { return }
        recordingTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { return }
                guard let self, !Task.isCancelled, state.capture == .recording else { return }
                recordingSeconds += 1
            }
        }
    }

    private func showRecordingHint(_ hint: RemoteRecordingHint) {
        let diagnostic = [hint.message, hint.diagnostic].compactMap { $0 }.joined(separator: "\n")
        recordingErrorReport = (recordingErrorReport + "\n" + diagnostic)
            .components(separatedBy: "\n").suffix(24).joined(separator: "\n")
        showMonitorHint(hint.message, source: .cameraRecording, durationNanoseconds: hint.durationNanoseconds)
        state = state.applying(.recordingFailed(hint))
    }

    func focus(at point: RemoteFocusPoint, coordinateSize: CGSize = CGSize(width: 1000, height: 1000)) {
        guard state.session == .ready, state.capture != .capturing,
              !stopRequested, !cameraToolWriting, tapFocusTask == nil, halfPressTask == nil, !halfPressHeld else { return }
        if state.focus.manual {
            showInteractionHint(AppLocalized.resource("remote_tap_focus_manual"))
            return
        }
        if state.focus.tracking {
            cancelTracking()
            return
        }
        guard state.focus.phase != .focusing else { return }
        confirmedFocusMarker = nil
        state = state.applying(.focusRequested(point))
        haptics.tick()
        focusHideTask?.cancel()
        // Android's final implementation uses the full enhanced-frame Live
        // View domain for both StartTracking and ChangeAfArea. The smaller
        // AF-frame grid is display metadata only.
        let trackingWidth = frameMetadata?.trackingCoordinateWidth ?? Int(coordinateSize.width)
        let trackingHeight = frameMetadata?.trackingCoordinateHeight ?? Int(coordinateSize.height)
        let focusWidth = trackingWidth
        let focusHeight = trackingHeight
        let trackingX = UInt32(rcNormalizedToFocusCoordinate(Float(point.x), size: trackingWidth))
        let trackingY = UInt32(rcNormalizedToFocusCoordinate(Float(point.y), size: trackingHeight))
        let focusX = UInt32(rcNormalizedToFocusCoordinate(Float(point.x), size: focusWidth))
        let focusY = UInt32(rcNormalizedToFocusCoordinate(Float(point.y), size: focusHeight))
        tapFocusTask = Task { [weak self] in
            guard let self else { return }
            defer { tapFocusTask = nil }
            guard !stopRequested else { return }
            do {
                let area = try? await camera.remoteCameraTool(.focusArea, movie: movieMode)
                let path = rcTapFocusPath(area, model: await camera.remoteDeviceModel())
                if path == .unsupported {
                    showInteractionHint(AppLocalized.resource("remote_tap_focus_area_unsupported"))
                    state = state.applying(.focusFailed)
                    confirmedFocusMarker = nil
                    scheduleFocusHide(after: 1.3)
                    return
                }
                let result = try await camera.focusAt(trackingX: trackingX, trackingY: trackingY,
                                                      focusX: focusX, focusY: focusY,
                                                      tapPath: path == .unknown ? nil : path)
                guard !Task.isCancelled, !stopRequested else { return }
                if result.timedOut || result.responseCode != PTPConstants.responseOK {
                    if !result.trackingStarted && result.moveResponseCode != PTPConstants.responseOK {
                        showInteractionHint(AppLocalized.resource("remote_tap_focus_area_retry"))
                    } else {
                        showInteractionHint(AppLocalized.resource("remote_tap_focus_retry"))
                    }
                    state = state.applying(.focusFailed)
                    state.focus.tracking = result.trackingStarted
                    if result.trackingStarted { focusAreaPoint = point }
                    confirmedFocusMarker = nil
                    scheduleFocusHide(after: 1.3)
                }
                else {
                    haptics.tick()
                    if result.trackingStarted || result.moveResponseCode == PTPConstants.responseOK {
                        focusAreaPoint = point
                    }
                    state.focus.tracking = result.trackingStarted
                    state = state.applying(.focusLocked)
                    setConfirmedFocusMarker(at: point, subjectTracking: result.trackingStarted)
                    let nonce = state.focus.nonce
                    focusHideTask = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(1_800))
                        guard let self, !Task.isCancelled, state.focus.nonce == nonce else { return }
                        state.focus.phase = .idle
                        state.focus.point = nil
                        guard !state.focus.tracking else { return }
                        try? await Task.sleep(for: .milliseconds(1_200))
                        guard !Task.isCancelled, state.focus.nonce == nonce,
                              !state.focus.tracking else { return }
                        confirmedFocusMarker = nil
                    }
                }
            } catch is CancellationError {
            } catch {
                guard !stopRequested else { return }
                if Self.isTransportFailure(error) { notifyTransportLost() }
                showInteractionHint(AppLocalized.resource("remote_tap_focus_retry"))
                state = state.applying(.focusFailed)
                confirmedFocusMarker = nil
                scheduleFocusHide(after: 1.3)
            }
        }
    }

    private func scheduleFocusHide(after seconds: Double) {
        let nonce = state.focus.nonce
        focusHideTask?.cancel()
        focusHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled, state.focus.nonce == nonce else { return }
            state.focus.phase = .idle
            state.focus.point = nil
        }
    }

    func showRotationLockHint(_ locked: Bool) {
        showInteractionHint(AppLocalized.resource(locked ? "remote_rotation_stopped" : "remote_rotation_resumed"))
    }

    private func showInteractionHint(_ message: String) {
        showMonitorHint(message)
    }

    func showMonitorHint(_ message: String, source: RemoteMonitorHint.Source = .interaction,
                         durationNanoseconds: UInt64 = 2_500_000_000) {
        guard !stopRequested else { return }
        monitorHintTask?.cancel()
        state = state.applying(.recordingHintDismissed)
        let nonce = monitorHint.nonce &+ 1
        monitorHint = RemoteMonitorHint(text: message, visible: true, source: source, nonce: nonce)
        monitorHintTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: durationNanoseconds) } catch { return }
            guard let self, !Task.isCancelled, monitorHint.nonce == nonce else { return }
            monitorHint.visible = false
            state = state.applying(.recordingHintDismissed)
            monitorHintTask = nil
        }
    }

    private func setConfirmedFocusMarker(at point: RemoteFocusPoint, subjectTracking: Bool) {
        confirmedFocusNonce &+= 1
        confirmedFocusMarker = RemoteConfirmedFocusMarker(
            fallbackPoint: point,
            confirmedAtUptime: ProcessInfo.processInfo.systemUptime,
            subjectTracking: subjectTracking,
            nonce: confirmedFocusNonce
        )
    }

    func cancelTracking() {
        guard state.focus.tracking, !stopRequested, tapFocusTask == nil else { return }
        haptics.tick()
        state = state.applying(.trackingEnded)
        state.focus.phase = .idle
        state.focus.point = nil
        let markerNonce = confirmedFocusMarker?.nonce
        focusHideTask?.cancel()
        focusHideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard let self, !Task.isCancelled,
                  confirmedFocusMarker?.nonce == markerNonce,
                  !state.focus.tracking else { return }
            confirmedFocusMarker = nil
        }
        tapFocusTask = Task { [weak self] in
            guard let self else { return }
            defer { tapFocusTask = nil }
            do { try await camera.endSubjectTracking() }
            catch {
                if Self.isTransportFailure(error) { notifyTransportLost() }
            }
        }
    }

    deinit {
        focusExpiryTask?.cancel()
        frameTask?.cancel()
        modeTask?.cancel()
        batteryTask?.cancel()
        storageTask?.cancel()
        movieFormatTask?.cancel()
        displayDetailsTask?.cancel()
        videoDiagnosticTask?.cancel()
        levelTask?.cancel()
        exposureMeterTask?.cancel()
        exposureMeterExpiryTask?.cancel()
        effectiveISOTask?.cancel()
        autoISOCommandTask?.cancel()
        for task in pendingSets.values { task.cancel() }
        focusHideTask?.cancel()
        halfPressTask?.cancel()
        tapFocusTask?.cancel()
        recordingTimerTask?.cancel()
        recordingCommandTask?.cancel()
        captureTask?.cancel()
        monitorHintTask?.cancel()
    }

    private static func message(for error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription { return description }
        return AppLocalized.resource("connection_failed_short")
    }

    private func notifyTransportLost() {
        guard !transportLossNotified else { return }
        usageMeter.stop()
        transportLossNotified = true
        stopRequested = true
        dismissCameraTool()
        modeTask?.cancel()
        frameImage = nil
        frameData = nil
        frameMetadata = nil
        monitorStorageFreeBytes = [:]
        frameHistogram = nil
        frameZebraMask = nil
        computerControlEnabled = false
        computerControlBusy = false
        frameDecodeGeneration &+= 1
        state = state.applying(.disconnected)
        onTransportLost?()
    }

    private static func isTransportFailure(_ error: Error) -> Bool {
        switch error {
        case PTPSessionError.timeout, PTPSessionError.invalidated,
             CameraTransportError.disconnected, CameraTransportError.timeout,
             CameraTransportError.unavailable:
            return true
        case let url as URLError:
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                    .notConnectedToInternet, .secureConnectionFailed].contains(url.code)
        default:
            return false
        }
    }
}
