import Foundation
import UIKit

@MainActor
final class RemoteViewModel: ObservableObject {
    @Published private(set) var state = RemoteState()
    @Published private(set) var frameImage: UIImage?
    @Published private(set) var frameData: Data?
    @Published private(set) var frameMetadata: RemoteLiveViewMetadata?
    @Published private(set) var exposureDescriptors: [RemoteExposureField: RemotePropertyDescriptor] = [:]
    @Published private(set) var movieMode = false
    // Android RemoteScreen starts in standard live view; the HD/XGA tool opts
    // into the enhanced frame operation for the following polls.
    @Published private(set) var hdLiveView = false
    @Published private(set) var autoISODescriptor: RemotePropertyDescriptor?
    @Published private(set) var focusModeDescriptor: RemotePropertyDescriptor?
    @Published private(set) var recordingSeconds = 0
    @Published private var recordingOperations = RemoteRecordingOperationGate()
    @Published private(set) var levelRoll: Double?
    @Published private(set) var batteryPercent: Int?

    var recordingBusy: Bool { recordingOperations.isBusy }
    var recordingHint: String? { state.recordingHint?.message }
    var transportLossWasNotified: Bool { transportLossNotified }


    private let camera: RemoteCameraControlling
    private let onTransportLost: (() -> Void)?
    private let haptics: ZTransferHaptics
    private var transportLossNotified = false
    private var frameTask: Task<Void, Never>?
    private var modeTask: Task<Void, Never>?
    private var batteryTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var levelVisible = false
    private var restartLiveView = false
    private var disposed = false
    private var initialLoaded = false
    private var batteryDescriptor: RemotePropertyDescriptor?
    @Published private(set) var exposureProgram: RemotePropertyDescriptor?
    private var focusHideTask: Task<Void, Never>?
    private var halfPressTask: Task<Void, Never>?
    private var halfPressHeld = false
    private var recordingTimerTask: Task<Void, Never>?
    private var recordingCommandTask: Task<Void, Never>?
    private var recordingHintTask: Task<Void, Never>?
    private var started = false
    // Teardown is cooperative. Cancelling an in-flight PTP request can
    // invalidate the camera session before the photo list resumes.
    private var stopRequested = false
    private var stopTrackingRequested = false
    private var lastFrameAt: ContinuousClock.Instant?

    init(camera: RemoteCameraControlling, onTransportLost: (() -> Void)? = nil,
         haptics: ZTransferHaptics = .shared) {
        self.camera = camera
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
                // RemoteScreen: selector -> matching exposure group -> Auto ISO
                // -> exposure mode -> focus -> battery, before starting Live View.
                movieMode = false
                if let selector = try? await camera.remoteProperty(.liveViewSelector) {
                    movieMode = selector.current == 1
                }
                state.movieMode = movieMode
                await loadExposure(movie: movieMode)
                if !stopRequested { exposureProgram = try? await camera.remoteProperty(.exposureProgram) }
                if !stopRequested { await refreshFocusMode() }
                if !stopRequested { await refreshBattery() }
                initialLoaded = !stopRequested
            }
            if initialLoaded { startPolling() }
            while !Task.isCancelled && !stopRequested {
                restartLiveView = false
                state = state.applying(.startRequested)
                lastFrameAt = nil
                do {
                    if let descriptor = try? await camera.remoteProperty(.liveViewImageSize), descriptor.writable {
                        try? await camera.setRemoteProperty(descriptor, value: hdLiveView ? 3 : 2)
                    }
                    if stopRequested { break }
                    try await camera.startLiveView()
                    if stopRequested { break }
                    started = true
                    state = state.applying(.deviceReady)
                    if camera.isUSB { try? await Task.sleep(for: .milliseconds(750)) }
                    var successes = 0
                    var errors = 0
                    var windowStart: ContinuousClock.Instant?
                    var intervals = 0
                    while !Task.isCancelled && !stopRequested && !restartLiveView {
                        do {
                            // Android probes the camera's advertised enhanced
                            // frame operation independently from the XGA/HD
                            // size switch. The HD toggle controls resolution,
                            // not whether metadata frames are requested.
                            let payload = try await camera.liveViewFrame(preferEnhanced: true)
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
                            if let jpegRange = RemoteFrameParser.jpegRange(in: payload),
                               let image = UIImage(data: Data(payload[jpegRange])) {
                                frameData = Data(payload[jpegRange])
                                frameImage = image
                                frameMetadata = RemoteFrameParser.metadata(from: payload, jpegOffset: jpegRange.lowerBound,
                                                                            operation: PTPConstants.getLiveViewImageEx)
                                state = state.applying(.frameReceived(fps: fps))
                            }
                            state.liveViewStable = !camera.isUSB || successes >= 8
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
            if stopTrackingRequested {
                try? await camera.endSubjectTracking()
                stopTrackingRequested = false
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
                for event in events where !stopRequested {
                    if event.code == 0x4006 {
                        await handlePropertyChanged(event.handle)
                    }
                }
                pollTick += 1
                if pollTick % 5 == 0 && !cameraBusy && !stopRequested { await refreshMovieMode() }
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
            await loadExposure(movie: movieMode)
            return
        }
        if raw == RemoteProperty.focusMode.rawValue || raw == RemoteProperty.nikonAFMode.rawValue {
            await refreshFocusMode()
            return
        }
        if RemoteExposureParameters.autoISOProperties(movie: movieMode).contains(where: { $0.rawValue == raw }) {
            await loadExposure(movie: movieMode)
            return
        }
        for (field, descriptor) in exposureDescriptors where descriptor.property.rawValue == raw {
            if let updated = try? await camera.refreshRemoteProperty(descriptor) {
                exposureDescriptors[field] = updated
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
              let descriptor = try? await camera.remoteProperty(.liveViewSelector) else { return }
        let nextMovie = descriptor.current == 1
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
        guard next.property == .batteryLevel,
              next.dataType == 0x0002,
              next.current <= 100 else { return }
        batteryDescriptor = next
        batteryPercent = Int(next.current)
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

    private func loadExposure(movie: Bool) async {
        var loaded: [RemoteExposureField: RemotePropertyDescriptor] = [:]
        for field in [RemoteExposureField.exposureCompensation, .iso, .aperture, .shutter] {
            for property in RemoteExposureParameters.compatibleProperties(for: field, movie: movie) {
                guard !stopRequested else { return }
                if let descriptor = try? await camera.remoteProperty(property) { loaded[field] = descriptor; break }
            }
        }
        guard !stopRequested else { return }
        exposureDescriptors = loaded
        autoISODescriptor = nil
        for property in RemoteExposureParameters.autoISOProperties(movie: movie) {
            guard !stopRequested else { return }
            if let descriptor = try? await camera.remoteProperty(property),
               descriptor.writable,
               ((descriptor.values.contains(0) && descriptor.values.contains(where: { $0 != 0 })) ||
                (descriptor.values.isEmpty && [0x0001, 0x0002].contains(descriptor.dataType) && descriptor.current <= 1)) {
                autoISODescriptor = descriptor
                break
            }
        }
    }

    var autoISOEnabled: Bool { autoISODescriptor?.current != 0 }

    func setLevelVisible(_ visible: Bool) {
        levelVisible = visible
        levelTask?.cancel()
        levelRoll = nil
        guard visible, !stopRequested else { return }
        levelTask = Task { [weak self] in
            guard let self else { return }
            var descriptor: RemotePropertyDescriptor?
            var failures = 0
            while !Task.isCancelled && !stopRequested && levelVisible {
                if descriptor == nil {
                    descriptor = try? await camera.remoteProperty(.angleLevel)
                    if descriptor == nil { levelVisible = false; break }
                }
                guard let current = descriptor else { break }
                if let refreshed = try? await camera.refreshRemoteProperty(current) {
                    let signed = Int64(bitPattern: refreshed.current)
                    levelRoll = (Double(signed) / 65536.0 * 10).rounded() / 10
                    descriptor = refreshed
                    failures = 0
                } else {
                    failures += 1
                    if failures >= 3 { levelRoll = nil; levelVisible = false; break }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// One feedback pulse per camera detent, matching RemoteScreen's
    /// onValueStep callback. The eventual write remains coalesced by the
    /// control and is committed once the drag ends.
    func detentFeedback() {
        haptics.tick()
    }

    func setAutoISO(_ enabled: Bool) {
        guard let descriptor = autoISODescriptor, descriptor.writable else { return }
        let previous = descriptor.current
        guard (previous != 0) != enabled else { return }
        var optimistic = descriptor
        optimistic.current = enabled ? 1 : 0
        autoISODescriptor = optimistic
        haptics.tick()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await camera.setRemoteProperty(descriptor, value: enabled ? 1 : 0)
                autoISODescriptor = try? await camera.remoteProperty(descriptor.property)
            } catch {
                if Self.isTransportFailure(error) { notifyTransportLost() }
                if var current = autoISODescriptor {
                    current.current = previous
                    autoISODescriptor = current
                }
            }
        }
    }

    func setExposure(_ field: RemoteExposureField, value: UInt64, feedback: Bool = true) {
        guard let descriptor = exposureDescriptors[field], descriptor.writable else { return }
        let previous = descriptor.current
        guard previous != value else { return }
        var optimistic = descriptor
        optimistic.current = value
        exposureDescriptors[field] = optimistic
        if feedback { haptics.tick() }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await camera.setRemoteProperty(descriptor, value: value)
                if let refreshed = try? await camera.remoteProperty(descriptor.property) {
                    exposureDescriptors[field] = refreshed
                }
            } catch {
                if Self.isTransportFailure(error) { notifyTransportLost() }
                if var current = exposureDescriptors[field] {
                    current.current = previous
                    exposureDescriptors[field] = current
                }
            }
        }
    }

    func stop() {
        disposed = true
        stopRequested = true
        halfPressHeld = false
        halfPressTask?.cancel()
        halfPressTask = nil
        levelTask?.cancel()
        levelTask = nil
        levelVisible = false
        stopTrackingRequested = state.focus.tracking
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
        lastFrameAt = nil
        state.focus = .init()
    }

    /// Waits for any active PTP operations to finish their normal protocol
    /// teardown before the photo list starts catalog work again.
    func stopAndWait() async {
        stop()
        let frame = frameTask
        let mode = modeTask
        let recording = recordingCommandTask
        await batteryTask?.value
        batteryTask = nil
        await frame?.value
        await mode?.value
        await recording?.value
        frameTask = nil
        modeTask = nil
        recordingCommandTask = nil
        await camera.setRemoteActive(false)
    }

    /// Starts the Android two-stage shutter AF. The initial tick is emitted
    /// when the half-press is accepted; the second tick only arrives while the
    /// finger is still held when AF actually locks.
    func beginHalfPress() {
        guard state.session == .ready, state.capture == .idle,
              !state.focus.manual, !halfPressHeld, halfPressTask == nil,
              !stopRequested else { return }
        halfPressHeld = true
        haptics.tick()
        halfPressTask = Task { [weak self] in
            guard let self else { return }
            defer { halfPressTask = nil }
            do {
                let result = try await camera.halfPressFocus()
                guard !Task.isCancelled, !stopRequested, halfPressHeld else { return }
                guard !result.timedOut else { return }
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
        guard halfPressHeld || halfPressTask != nil else {
            if fire { capture() }
            return
        }
        halfPressHeld = false
        let pending = halfPressTask
        guard fire else { return }
        Task { [weak self] in
            guard let self else { return }
            await pending?.value
            guard !Task.isCancelled, !stopRequested, state.session == .ready,
                  state.capture == .idle else { return }
            if movieMode { toggleRecording() }
            else { capture() }
        }
    }

    func capture() {
        guard state.session == .ready, state.capture == .idle, !movieMode else { return }
        state = state.applying(.captureRequested)
        Task { [weak self] in
            guard let self else { return }
            do {
                guard !Task.isCancelled, !stopRequested, state.session == .ready,
                      state.capture == .capturing else { return }
                haptics.longPress()
                try await camera.capturePhoto()
                guard !Task.isCancelled, !stopRequested else { return }
                state = state.applying(.captureConfirmed)
            } catch is CancellationError {
                state = state.applying(.cancelled)
            } catch {
                if Self.isTransportFailure(error) { notifyTransportLost() }
                state = state.applying(.operationFailed(Self.message(for: error)))
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
                guard !Task.isCancelled, !stopRequested else { return }
                haptics.longPress()
                switch command {
                case .start:
                    let result = try await camera.startMovieRecording()
                    guard !Task.isCancelled, recordingOperations.accepts(token) else { return }
                    if result.indicatesRecording { setRecording(true) }
                    else { showRecordingHint(.startFailed(result)) }
                case .stop:
                    // Android retains recording + its timer until EndMovieRec
                    // succeeds. A failed command cannot pretend the camera stopped.
                    let response = try await camera.endMovieRecording()
                    guard !Task.isCancelled, recordingOperations.accepts(token) else { return }
                    if response == PTPConstants.responseOK { setRecording(false) }
                    else { showRecordingHint(.stopFailed(responseCode: response)) }
                }
            } catch is CancellationError {
                // Leaving cancels ownership; no hint or late recording state.
            } catch {
                guard !Task.isCancelled, recordingOperations.accepts(token) else { return }
                if Self.isTransportFailure(error) { notifyTransportLost() }
                showRecordingHint(command == .start ? .startFailed(nil) : .stopFailed())
            }
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
        guard state.session == .ready, state.capture == .idle, !state.focus.manual else { return }
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
        let focusWidth = frameMetadata?.focusCoordinateWidth ?? trackingWidth
        let focusHeight = frameMetadata?.focusCoordinateHeight ?? trackingHeight
        let trackingX = UInt32((point.x * Double(max(1, trackingWidth - 1))).rounded())
        let trackingY = UInt32((point.y * Double(max(1, trackingHeight - 1))).rounded())
        let focusX = UInt32((point.x * Double(max(1, focusWidth - 1))).rounded())
        let focusY = UInt32((point.y * Double(max(1, focusHeight - 1))).rounded())
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await camera.focusAt(trackingX: trackingX, trackingY: trackingY,
                                                      focusX: focusX, focusY: focusY)
                guard !Task.isCancelled, !stopRequested else { return }
                if result.timedOut { state = state.applying(.focusFailed); scheduleFocusHide(after: 1.2) }
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
                if Self.isTransportFailure(error) { notifyTransportLost() }
                state = state.applying(.focusFailed)
                scheduleFocusHide(after: 1.2)
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
        guard state.focus.tracking else { return }
        haptics.tick()
        Task { [weak self] in
            guard let self else { return }
            do { try await camera.endSubjectTracking() }
            catch {
                if Self.isTransportFailure(error) { notifyTransportLost() }
            }
            state = state.applying(.trackingEnded)
        }
    }

    deinit {
        frameTask?.cancel()
        modeTask?.cancel()
        batteryTask?.cancel()
        levelTask?.cancel()
        focusHideTask?.cancel()
        halfPressTask?.cancel()
        recordingTimerTask?.cancel()
        recordingCommandTask?.cancel()
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

private enum RemoteViewModelError: Error { case invalidFrame }
