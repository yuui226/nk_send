import AVFoundation
import Foundation
import UIKit

@MainActor
final class RemoteViewModel: ObservableObject {
    @Published private(set) var state = RemoteState()
    @Published private(set) var frameImage: UIImage?
    @Published private(set) var frameData: Data?
    @Published private(set) var frameMetadata: RemoteLiveViewMetadata?
    @Published private(set) var frameHistogram: [Int]?
    @Published private(set) var frameZebraMask: RemoteZebraMask?
    @Published private(set) var exposureDescriptors: [RemoteExposureField: RemotePropertyDescriptor] = [:]
    private var exposureDescriptorCache: [Bool: [RemoteExposureField: RemotePropertyDescriptor]] = [:]
    @Published private(set) var movieMode = false
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
    @Published private(set) var localRecordingHint: String?
    @Published private var recordingOperations = RemoteRecordingOperationGate()
    @Published private(set) var levelRoll: Double?
    @Published private(set) var batteryPercent: Int?

    var recordingBusy: Bool { recordingOperations.isBusy }
    var recordingHint: String? { state.recordingHint?.message }
    var transportLossWasNotified: Bool { transportLossNotified }


    private let camera: RemoteCameraControlling
    private let onTransportLost: (() -> Void)?
    private let haptics: ZTransferHaptics
    private let recordingDirectory: URL?
    private var transportLossNotified = false
    private var frameTask: Task<Void, Never>?
    private var modeTask: Task<Void, Never>?
    private var batteryTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    @Published private(set) var levelVisible = false
    private var levelGeneration = 0
    private var restartLiveView = false
    private var liveViewPauseRequested = false
    private var liveViewPaused = false
    private var adoptStartedLiveView = false
    private var disposed = false
    private var initialLoaded = false
    private var batteryDescriptor: RemotePropertyDescriptor?
    @Published private(set) var exposureProgram: RemotePropertyDescriptor?
    private var focusHideTask: Task<Void, Never>?
    private var halfPressTask: Task<Void, Never>?
    private var tapFocusTask: Task<Void, Never>?
    private var halfPressHeld = false
    private var recordingTimerTask: Task<Void, Never>?
    private var recordingCommandTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var captureObjectAdded = false
    private var lastStopCommandAt: ContinuousClock.Instant?
    private var recordingHintTask: Task<Void, Never>?
    private var localRecorder: RemoteViewfinderRecorder?
    private var localRecordingTask: Task<Void, Never>?
    private var localRecordingTimerTask: Task<Void, Never>?
    private var localRecordingHintTask: Task<Void, Never>?
    private var localRecordingSavedTask: Task<Void, Never>?
    private var movieCleanupTask: Task<Void, Never>?
    private var movieCompletionSequence = 0
    private var stopMovieOnExit = false
    private var started = false
    // Teardown is cooperative. Cancelling an in-flight PTP request can
    // invalidate the camera session before the photo list resumes.
    private var stopRequested = false
    private var lastFrameAt: ContinuousClock.Instant?
    private var frameDecodeGeneration: UInt64 = 0
    private var histogramEnabled = false
    private var zebraEnabled = false
    private lazy var frameDecoder = RemoteFrameDecodePipeline { [weak self] decoded in
        self?.acceptDecodedFrame(decoded)
    }

    init(camera: RemoteCameraControlling, recordingDirectory: URL? = nil,
         onTransportLost: (() -> Void)? = nil,
         haptics: ZTransferHaptics = .shared) {
        self.camera = camera
        self.recordingDirectory = recordingDirectory
        self.onTransportLost = onTransportLost
        self.haptics = haptics
    }

    func start() {
        guard frameTask == nil, !disposed else { return }
        stopRequested = false
        transportLossNotified = false
        state = state.applying(.startRequested)
        frameTask = Task { [weak self] in
            guard let self else { return }
            await camera.setRemoteActive(true)
            if !stopRequested {
                if camera.isUSB, await camera.hasRemoteControlMode() {
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
            }
            if initialLoaded { startPolling() }
            while !Task.isCancelled && !stopRequested {
                while liveViewPauseRequested && !stopRequested {
                    liveViewPaused = true
                    try? await Task.sleep(for: .milliseconds(10))
                }
                liveViewPaused = false
                restartLiveView = false
                frameDecodeGeneration &+= 1
                let decodeGeneration = frameDecodeGeneration
                await frameDecoder.reset(generation: decodeGeneration)
                await frameDecoder.setAnalysis(histogram: histogramEnabled, zebra: zebraEnabled)
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
                    if camera.isUSB { try? await Task.sleep(for: .milliseconds(750)) }
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
                            try? await Task.sleep(for: .milliseconds(40))
                        } catch {
                            if Self.isTransportFailure(error) { notifyTransportLost(); break }
                            errors += 1
                            if errors >= 3 { break }
                            try? await Task.sleep(for: .milliseconds(300))
                        }
                    }
                    state.liveViewStable = false
                    updateEffectiveISOPolling()
                    state.fps = 0
                    await camera.endLiveView()
                    started = false
                    if !stopRequested && !restartLiveView { try? await Task.sleep(for: .seconds(2)) }
                } catch is CancellationError { break }
                catch {
                    if Self.isTransportFailure(error) { notifyTransportLost(); break }
                    state = state.applying(.frameLost)
                    // Android retries failed LV startup for the lifetime of the page.
                    if !stopRequested { try? await Task.sleep(for: .seconds(3)) }
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
                    try? await Task.sleep(for: .milliseconds(600))
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
                try? await Task.sleep(for: .milliseconds(state.capture == .capturing ? 150 : 600))
            }
        }
        batteryTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && !stopRequested {
                await pause(for: .seconds(120))
                while !stopRequested && (!state.liveViewStable || cameraBusy) {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
                if !stopRequested { await refreshBattery() }
            }
        }
    }

    private func handlePropertyChanged(_ raw: UInt32) async {
        guard !stopRequested else { return }
        if raw == RemoteProperty.batteryLevel.rawValue {
            await refreshBattery()
            return
        }
        if raw == RemoteProperty.liveViewSelector.rawValue {
            if !cameraBusy { await refreshMovieMode() }
            return
        }
        if raw == RemoteProperty.exposureProgram.rawValue {
            exposureProgram = try? await camera.remoteProperty(.exposureProgram)
            await loadExposure(movie: movieMode, preservingPending: true)
            return
        }
        if raw == RemoteProperty.focusMode.rawValue || raw == RemoteProperty.nikonAFMode.rawValue {
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
            try? await Task.sleep(for: min(.milliseconds(100), ContinuousClock.now.duration(to: deadline)))
        }
    }

    private func refreshMovieMode() async {
        guard !stopRequested,
              let nextMovie = try? await camera.remoteMovieMode() else { return }
        if nextMovie != movieMode {
            movieMode = nextMovie
            state.movieMode = nextMovie
            await loadExposure(movie: nextMovie)
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
        focusModeDescriptor = try? await camera.remoteFocusMode()
        state.focus.manual = focusModeDescriptor?.property == .focusMode && focusModeDescriptor?.current == 1
    }

    func setHDLiveView(_ enabled: Bool) {
        guard hdLiveView != enabled, !stopRequested else { return }
        hdLiveView = enabled
        // Cooperatively finish the command on the wire. EndLiveView precedes
        // the new size write/start, without releasing the page's remote gate.
        restartLiveView = true
    }

    func setFrameAnalysis(histogram: Bool, zebra: Bool) {
        histogramEnabled = histogram
        zebraEnabled = zebra
        if !histogram { frameHistogram = nil }
        if !zebra { frameZebraMask = nil }
        Task { [frameDecoder] in
            await frameDecoder.setAnalysis(histogram: histogram, zebra: zebra)
        }
    }

    private func acceptDecodedFrame(_ decoded: RemoteDecodedFrame) {
        guard !stopRequested, decoded.generation == frameDecodeGeneration else { return }
        frameData = decoded.jpeg
        frameImage = decoded.image
        frameMetadata = decoded.metadata
        frameHistogram = decoded.histogram
        frameZebraMask = decoded.zebraMask
        state = state.applying(.frameReceived(fps: decoded.fps))
        if localRecordingPhase == .recording {
            localRecorder?.append(image: decoded.image, receivedAtUptime: decoded.receivedAtUptime)
        }
    }

    func startLocalRecording() {
        guard localRecordingPhase == .idle || localRecordingPhase == .saved,
              localRecorder == nil, let image = frameImage else {
            if frameImage == nil { showLocalRecordingHint(AppLocalized.resource("remote_rec_start_failed")) }
            return
        }
        localRecordingTask?.cancel()
        localRecordingTask = Task { [weak self] in
            guard let self else { return }
            let permission = await microphonePermission()
            guard !Task.isCancelled, !stopRequested else { return }
            if !permission {
                showLocalRecordingHint(AppLocalized.resource("remote_rec_no_audio"))
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
            localRecorder?.resume()
            localRecordingPhase = .recording
        default: break
        }
    }

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
                showLocalRecordingHint(AppLocalized.resource("cd_remote_rec_toast_failed"))
            }
        }
    }

    private func startLocalRecordingResolved(size: CGSize, withAudio: Bool) {
        let preferred = RemoteViewfinderRecorder.outputURL(preferredDirectory: recordingDirectory)
        var recorder = RemoteViewfinderRecorder(outputURL: preferred, sourceSize: size, withAudio: withAudio)
        var started = recorder.start()
        if !started, recordingDirectory != nil {
            recorder = RemoteViewfinderRecorder(
                outputURL: RemoteViewfinderRecorder.outputURL(preferredDirectory: nil),
                sourceSize: size,
                withAudio: withAudio
            )
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

    private func showLocalRecordingHint(_ message: String) {
        localRecordingHintTask?.cancel()
        localRecordingHint = message
        localRecordingHintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.localRecordingHint = nil
        }
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
            let described = try? await camera.remoteProperty(.angleLevel)
            guard active() else { return }
            guard var param = described, param.angleLevelRoll != nil else {
                levelVisible = false
                return
            }
            var failures = 0
            while active() {
                if let roll = param.angleLevelRoll {
                    // Kotlin roundToInt resolves halfway values toward positive infinity.
                    levelRoll = floor(roll * 10 + 0.5) / 10
                }
                try? await Task.sleep(for: .milliseconds(250))
                guard active() else { return }
                let refreshed = try? await camera.refreshRemoteProperty(param)
                guard active() else { return }
                if let refreshed { param = refreshed; failures = 0 }
                else {
                    failures += 1
                    // Android clears the stale angle after three failures but
                    // leaves the user's switch on; toggling off/on retries.
                    if failures >= 3 { levelRoll = nil; return }
                }
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
                if current == nil { try? await Task.sleep(for: .milliseconds(150)) }
            }
            guard active(), var descriptor = current else { return }
            effectiveISO = descriptor
            while active() {
                if let next = try? await camera.refreshRemoteProperty(descriptor), active() {
                    descriptor = next
                    effectiveISO = next
                }
                try? await Task.sleep(for: .milliseconds(500))
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

    private func remoteCommandsAllowed() -> Bool { !stopRequested }

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

    func stop() {
        disposed = true
        stopRequested = true
        stopMovieOnExit = state.capture == .recording || state.capture == .stopping
        effectiveISOGeneration &+= 1
        halfPressHeld = false
        levelGeneration &+= 1
        levelVisible = false
        levelRoll = nil
        focusHideTask?.cancel()
        recordingOperations.invalidate()
        recordingTimerTask?.cancel()
        recordingTimerTask = nil
        recordingHintTask?.cancel()
        recordingHintTask = nil
        recordingSeconds = 0
        state = state.applying(.cancelled)
        frameImage = nil
        frameData = nil
        frameMetadata = nil
        frameHistogram = nil
        frameZebraMask = nil
        frameDecodeGeneration &+= 1
        lastFrameAt = nil
        state.focus = .init()
    }

    /// Waits for any active PTP operations to finish their normal protocol
    /// teardown before the photo list starts catalog work again.
    func stopAndWait() async {
        if localRecordingPhase == .recording || localRecordingPhase == .paused { stopLocalRecording() }
        stop()
        let frame = frameTask
        let mode = modeTask
        let recording = recordingCommandTask
        await halfPressTask?.value
        await tapFocusTask?.value
        await batteryTask?.value
        batteryTask = nil
        await effectiveISOTask?.value
        effectiveISOTask = nil
        await autoISOCommandTask?.value
        for task in pendingSets.values { await task.value }
        pendingSets.removeAll()
        await levelTask?.value
        levelTask = nil
        await frame?.value
        await frameDecoder.reset(generation: frameDecodeGeneration)
        await frameDecoder.waitUntilIdle()
        await mode?.value
        await recording?.value
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
        await releaseMovieSessionToStandby(resumeLiveView: false)
        await camera.setRemoteActive(false)
    }

    /// Starts the Android two-stage shutter AF. The initial tick is emitted
    /// when the half-press is accepted; the second tick only arrives while the
    /// finger is still held when AF actually locks.
    func beginHalfPress() {
        guard state.session == .ready, state.capture == .idle,
              !state.focus.manual, !halfPressHeld, halfPressTask == nil, tapFocusTask == nil,
              !stopRequested else { return }
        halfPressHeld = true
        state.focus.tracking = false
        haptics.tick()
        halfPressTask = Task { [weak self] in
            guard let self else { return }
            defer { halfPressTask = nil }
            do {
                let result = try await camera.halfPressFocus()
                guard !Task.isCancelled, !stopRequested, halfPressHeld else { return }
                guard !result.timedOut, result.responseCode == PTPConstants.responseOK else { return }
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
        guard fire, !stopRequested else { return }
        // Set shutter/record busy synchronously; those tasks wait for the AF
        // transaction before sending their command and starting confirmation.
        if movieMode { toggleRecording() }
        else { capture() }
    }

    func capture() {
        guard state.session == .ready, state.capture == .idle, !movieMode, !stopRequested else { return }
        state = state.applying(.captureRequested)
        captureTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if !stopRequested { state = state.applying(.captureConfirmed) }
                captureTask = nil
            }
            // Android starts the twelve-second confirmation window only after
            // the pending AF transaction has reached its terminal response.
            await halfPressTask?.value
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

    func toggleRecording() {
        guard movieMode, state.session == .ready else { return }
        let command: RemoteRecordingCommand
        if state.capture == .recording || state.capture == .stopping { command = .stop }
        else if state.capture == .idle { command = .start }
        else { return }
        guard let token = recordingOperations.begin(command) else { return }

        recordingCommandTask = Task { [weak self] in
            guard let self else { return }
            defer {
                // An old command must not release a newer page's busy owner.
                if recordingOperations.complete(token) { recordingCommandTask = nil }
            }
            do {
                await halfPressTask?.value
                guard !Task.isCancelled, !stopRequested else { return }
                haptics.longPress()
                switch command {
                case .start:
                    var result: RemoteMovieStartResult
                    var adopted = false
                    if camera.isUSB {
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
                        result = try await camera.startPreparedUSBMovieRecording()
                        resumeLiveViewAfterMovieTransition(adoptStarted: true)
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
                if Self.isTransportFailure(error) { notifyTransportLost() }
                if liveViewPauseRequested { resumeLiveViewAfterMovieTransition(adoptStarted: false) }
                await releaseMovieSessionToStandby(resumeLiveView: true)
                showRecordingHint(command == .start ? .startFailed(nil) : .stopFailed())
            }
        }
    }

    private func pauseLiveViewForMovieTransition() async {
        guard !stopRequested else { return }
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

    private func releaseMovieSessionToStandby(resumeLiveView: Bool) async {
        let hasControl = await camera.hasRemoteControlMode()
        let hasApplication = await camera.hasMovieApplicationMode()
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
        if resumeLiveView && !stopRequested {
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
        recordingHintTask?.cancel()
        state = state.applying(.recordingFailed(hint))
        recordingHintTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: hint.durationNanoseconds) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            state = state.applying(.recordingHintDismissed)
        }
    }

    func focus(at point: RemoteFocusPoint, coordinateSize: CGSize = CGSize(width: 1000, height: 1000)) {
        guard state.session == .ready, state.capture != .capturing, !state.focus.manual,
              !stopRequested, tapFocusTask == nil, halfPressTask == nil, !halfPressHeld else { return }
        if state.focus.tracking {
            cancelTracking()
            return
        }
        guard state.focus.phase != .focusing else { return }
        state = state.applying(.focusRequested(point))
        haptics.tick()
        focusHideTask?.cancel()
        // Android uses two coordinate spaces from the enhanced frame header:
        // the full image space for StartTracking and the AF grid for
        // ChangeAfArea. Never reuse the JPEG dimensions for both commands.
        let trackingWidth = frameMetadata?.trackingCoordinateWidth ?? Int(coordinateSize.width)
        let trackingHeight = frameMetadata?.trackingCoordinateHeight ?? Int(coordinateSize.height)
        let focusWidth = frameMetadata?.focusCoordinateWidth ?? Int(coordinateSize.width)
        let focusHeight = frameMetadata?.focusCoordinateHeight ?? Int(coordinateSize.height)
        let trackingX = UInt32((point.x * Double(max(0, trackingWidth - 1))).rounded())
        let trackingY = UInt32((point.y * Double(max(0, trackingHeight - 1))).rounded())
        let focusX = UInt32((point.x * Double(max(0, focusWidth - 1))).rounded())
        let focusY = UInt32((point.y * Double(max(0, focusHeight - 1))).rounded())
        tapFocusTask = Task { [weak self] in
            guard let self else { return }
            defer { tapFocusTask = nil }
            guard !stopRequested else { return }
            do {
                let result = try await camera.focusAt(trackingX: trackingX, trackingY: trackingY,
                                                      focusX: focusX, focusY: focusY)
                guard !Task.isCancelled, !stopRequested else { return }
                if result.timedOut || result.responseCode != PTPConstants.responseOK {
                    state = state.applying(.focusFailed)
                    state.focus.tracking = result.trackingStarted
                    scheduleFocusHide(after: 1.3)
                }
                else {
                    haptics.tick()
                    state.focus.tracking = result.trackingStarted
                    state = state.applying(.focusLocked)
                    let nonce = state.focus.nonce
                    focusHideTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        guard let self, !Task.isCancelled, state.focus.nonce == nonce,
                              !state.focus.tracking else { return }
                        state.focus.phase = .idle
                        state.focus.point = nil
                    }
                }
            } catch is CancellationError {
            } catch {
                guard !stopRequested else { return }
                if Self.isTransportFailure(error) { notifyTransportLost() }
                state = state.applying(.focusFailed)
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

    func cancelTracking() {
        guard state.focus.tracking, !stopRequested, tapFocusTask == nil else { return }
        haptics.tick()
        state = state.applying(.trackingEnded)
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
        frameTask?.cancel()
        modeTask?.cancel()
        batteryTask?.cancel()
        levelTask?.cancel()
        effectiveISOTask?.cancel()
        autoISOCommandTask?.cancel()
        for task in pendingSets.values { task.cancel() }
        focusHideTask?.cancel()
        halfPressTask?.cancel()
        tapFocusTask?.cancel()
        recordingTimerTask?.cancel()
        recordingCommandTask?.cancel()
        captureTask?.cancel()
        recordingHintTask?.cancel()
    }

    private static func message(for error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription { return description }
        return AppLocalized.resource("connection_failed_short")
    }

    private func notifyTransportLost() {
        guard !transportLossNotified else { return }
        transportLossNotified = true
        stopRequested = true
        modeTask?.cancel()
        frameImage = nil
        frameData = nil
        frameMetadata = nil
        frameHistogram = nil
        frameZebraMask = nil
        frameDecodeGeneration &+= 1
        state = state.applying(.disconnected)
        onTransportLost?()
    }

    private static func isTransportFailure(_ error: Error) -> Bool {
        switch error {
        case PTPSessionError.timeout, PTPSessionError.invalidated,
             CameraTransportError.disconnected, CameraTransportError.timeout:
            return true
        case let url as URLError:
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                    .notConnectedToInternet, .secureConnectionFailed].contains(url.code)
        default:
            return false
        }
    }
}
