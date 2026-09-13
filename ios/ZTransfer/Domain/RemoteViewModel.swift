import Foundation
import UIKit

@MainActor
final class RemoteViewModel: ObservableObject {
    @Published private(set) var state = RemoteState()
    @Published private(set) var frameImage: UIImage?
    @Published private(set) var frameData: Data?
    @Published private(set) var exposureDescriptors: [RemoteExposureField: RemotePropertyDescriptor] = [:]
    @Published private(set) var movieMode = false
    @Published private(set) var autoISODescriptor: RemotePropertyDescriptor?
    @Published private(set) var focusModeDescriptor: RemotePropertyDescriptor?
    @Published private(set) var recordingSeconds = 0
    @Published private var recordingOperations = RemoteRecordingOperationGate()
    @Published private(set) var levelRoll: Double?

    var recordingBusy: Bool { recordingOperations.isBusy }
    var recordingHint: String? { state.recordingHint?.message }

    private let camera: RemoteCameraControlling
    private var frameTask: Task<Void, Never>?
    private var modeTask: Task<Void, Never>?
    private var focusHideTask: Task<Void, Never>?
    private var recordingTimerTask: Task<Void, Never>?
    private var recordingCommandTask: Task<Void, Never>?
    private var recordingHintTask: Task<Void, Never>?
    private var started = false
    private var lastFrameAt: ContinuousClock.Instant?

    init(camera: RemoteCameraControlling) { self.camera = camera }

    func start() {
        guard frameTask == nil else { return }
        state = state.applying(.startRequested)
        frameTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await camera.startLiveView()
                guard !Task.isCancelled else { return }
                started = true
                state = state.applying(.deviceReady)
                while !Task.isCancelled {
                    do {
                        let payload = try await camera.liveViewFrame(preferEnhanced: true)
                        guard let data = RemoteFrameParser.jpegData(from: payload),
                              let image = UIImage(data: data) else {
                            throw RemoteViewModelError.invalidFrame
                        }
                        let now = ContinuousClock.now
                        let rate: Double
                        if let previous = lastFrameAt {
                            let duration = previous.duration(to: now)
                            let seconds = Double(duration.components.seconds) +
                                Double(duration.components.attoseconds) / 1e18
                            rate = seconds > 0 ? 1 / seconds : 0
                        } else { rate = 0 }
                        lastFrameAt = now
                        frameData = data
                        frameImage = image
                        state = state.applying(.frameReceived(fps: rate))
                    } catch is CancellationError {
                        break
                    } catch {
                        state = state.applying(.frameLost)
                        // Android keeps the session alive and retries the next frame;
                        // a short yield prevents a camera error from spinning the CPU.
                        try? await Task.sleep(nanoseconds: 80_000_000)
                    }
                }
            } catch is CancellationError {
                // Stop is the normal lifecycle path; do not surface a fake error.
            } catch {
                state = state.applying(.operationFailed(Self.message(for: error)))
            }
            await camera.endLiveView()
            started = false
        }
        modeTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if let descriptor = try? await camera.remoteProperty(.liveViewSelector),
                   descriptor.current <= 1 {
                    let nextMovie = descriptor.current == 1
                    if nextMovie != movieMode {
                        movieMode = nextMovie
                        state.movieMode = nextMovie
                        loadExposure(movie: nextMovie)
                    }
                }
                if let descriptor = try? await camera.remoteProperty(.angleLevel) {
                    let signed = Int64(bitPattern: descriptor.current)
                    levelRoll = Double(signed) / 65536
                }
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }
    }

    func loadExposure(movie: Bool) {
        Task { [weak self] in
            guard let self else { return }
            var loaded: [RemoteExposureField: RemotePropertyDescriptor] = [:]
            for field in [RemoteExposureField.exposureCompensation, .iso, .aperture, .shutter] {
                for property in RemoteExposureParameters.compatibleProperties(for: field, movie: movie) {
                    if let descriptor = try? await camera.remoteProperty(property) {
                        loaded[field] = descriptor
                        break
                    }
                }
            }
            exposureDescriptors = loaded
            autoISODescriptor = nil
            for property in RemoteExposureParameters.autoISOProperties(movie: movie) {
                if let descriptor = try? await camera.remoteProperty(property) {
                    autoISODescriptor = descriptor
                    break
                }
            }
            focusModeDescriptor = try? await camera.remoteProperty(.focusMode)
            state.focus.manual = focusModeDescriptor?.current == 1
        }
    }

    var autoISOEnabled: Bool { autoISODescriptor?.current != 0 }

    func setAutoISO(_ enabled: Bool) {
        guard let descriptor = autoISODescriptor, descriptor.writable else { return }
        let previous = descriptor.current
        var optimistic = descriptor
        optimistic.current = enabled ? 1 : 0
        autoISODescriptor = optimistic
        Task { [weak self] in
            guard let self else { return }
            do {
                try await camera.setRemoteProperty(descriptor, value: enabled ? 1 : 0)
                autoISODescriptor = try? await camera.remoteProperty(descriptor.property)
            } catch {
                if var current = autoISODescriptor {
                    current.current = previous
                    autoISODescriptor = current
                }
            }
        }
    }

    func setExposure(_ field: RemoteExposureField, value: UInt64) {
        guard let descriptor = exposureDescriptors[field], descriptor.writable else { return }
        let previous = descriptor.current
        var optimistic = descriptor
        optimistic.current = value
        exposureDescriptors[field] = optimistic
        Task { [weak self] in
            guard let self else { return }
            do {
                try await camera.setRemoteProperty(descriptor, value: value)
                if let refreshed = try? await camera.remoteProperty(descriptor.property) {
                    exposureDescriptors[field] = refreshed
                }
            } catch {
                if var current = exposureDescriptors[field] {
                    current.current = previous
                    exposureDescriptors[field] = current
                }
            }
        }
    }

    func stop() {
        focusHideTask?.cancel()
        recordingOperations.invalidate()
        recordingCommandTask?.cancel()
        recordingCommandTask = nil
        recordingTimerTask?.cancel()
        recordingTimerTask = nil
        recordingHintTask?.cancel()
        recordingHintTask = nil
        recordingSeconds = 0
        if state.focus.tracking { Task { try? await camera.endSubjectTracking() } }
        frameTask?.cancel()
        modeTask?.cancel()
        frameTask = nil
        modeTask = nil
        state = state.applying(.cancelled)
        frameImage = nil
        frameData = nil
        lastFrameAt = nil
        state.focus = .init()
    }

    func capture() {
        guard state.session == .ready, state.capture == .idle, !movieMode else { return }
        state = state.applying(.captureRequested)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await camera.capturePhoto()
                state = state.applying(.captureConfirmed)
            } catch is CancellationError {
                state = state.applying(.cancelled)
            } catch {
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
        focusHideTask?.cancel()
        let trackingX = UInt32((point.x * Double(max(1, Int(coordinateSize.width) - 1))).rounded())
        let trackingY = UInt32((point.y * Double(max(1, Int(coordinateSize.height) - 1))).rounded())
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await camera.focusAt(trackingX: trackingX, trackingY: trackingY,
                                                      focusX: trackingX, focusY: trackingY)
                guard !Task.isCancelled else { return }
                if result.timedOut { state = state.applying(.focusFailed); scheduleFocusHide(after: 1.2) }
                else {
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
        Task { [weak self] in
            guard let self else { return }
            try? await camera.endSubjectTracking()
            state = state.applying(.trackingEnded)
        }
    }

    deinit {
        frameTask?.cancel()
        modeTask?.cancel()
        focusHideTask?.cancel()
        recordingTimerTask?.cancel()
        recordingCommandTask?.cancel()
        recordingHintTask?.cancel()
    }

    private static func message(for error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription { return description }
        return "监看连接失败"
    }
}

private enum RemoteViewModelError: Error { case invalidFrame }
