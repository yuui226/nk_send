import Foundation

/// Observable state used by the remote monitor. The cases mirror the Android
/// RemoteScreen lifecycle: entering the page starts a session, a camera frame
/// makes it ready, and leaving or losing the camera tears it down.
enum RemoteSessionPhase: Equatable, Sendable {
    case idle
    case starting
    case warmingUp
    case ready
    case recovering
    case failed(String)
}

enum RemoteCapturePhase: Equatable, Sendable {
    case idle
    case focusing
    case capturing
    case recording
    case stopping
    case failed(String)
}

struct RemoteState: Equatable, Sendable {
    var session: RemoteSessionPhase = .idle
    var capture: RemoteCapturePhase = .idle
    var movieMode = false
    var liveViewStable = false
    var frameSequence: UInt64 = 0
    var fps: Double = 0
    var exposure: RemoteExposure = .init()
    var focus: RemoteFocusState = .init()
    var recordingHint: RemoteRecordingHint?
    var errorMessage: String?
}

struct RemoteExposure: Equatable, Sendable {
    var exposureCompensation: Int64?
    var iso: Int64?
    var aperture: Int64?
    var shutter: Int64?

    init(exposureCompensation: Int64? = nil, iso: Int64? = nil,
         aperture: Int64? = nil, shutter: Int64? = nil) {
        self.exposureCompensation = exposureCompensation
        self.iso = iso
        self.aperture = aperture
        self.shutter = shutter
    }
}

struct RemoteFocusState: Equatable, Sendable {
    var manual = false
    var tracking = false
    var phase: RemoteFocusPhase = .idle
    var point: RemoteFocusPoint?
    var nonce: UInt64 = 0
    var rollDegrees: Double?
}

enum RemoteFocusPhase: Equatable, Sendable { case idle, focusing, locked, failed }

struct RemoteFocusPoint: Equatable, Sendable {
    let x: Double
    let y: Double
    init(x: Double, y: Double) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
    }
}

struct RemoteConfirmedFocusMarker: Equatable, Sendable {
    let fallbackPoint: RemoteFocusPoint
    let confirmedAtUptime: TimeInterval
    let subjectTracking: Bool
    let nonce: UInt64

    // Android RemoteScreen fallback excludes subject tracking and lasts three seconds.
    func fallbackPoint(at uptime: TimeInterval) -> RemoteFocusPoint? {
        !subjectTracking && uptime - confirmedAtUptime < 3 ? fallbackPoint : nil
    }
}

/// Android FocusReticleOverlay shares one handoff latch across both drawing layers.
struct RemoteFocusHandoff: Equatable {
    struct Input: Equatable {
        let nonce: UInt64
        let phase: RemoteFocusPhase
        let eligible: Bool
        let hasCameraFrames: Bool
        var candidate: Bool { phase == .locked && eligible && hasCameraFrames }
    }
    private var input: Input?
    private var handedOff = false

    mutating func update(_ next: Input) {
        if input?.nonce != next.nonce || (input?.phase == .focusing) != (next.phase == .focusing) {
            handedOff = false
        }
        input = next
    }

    mutating func complete(_ expected: Input) {
        guard input == expected, expected.candidate else { return }
        handedOff = true
    }

    func visibility(for next: Input) -> (tap: Bool, camera: Bool) {
        var current = self
        current.update(next)
        let suppress = next.phase == .focusing || next.phase == .failed ||
            (next.phase == .locked && !current.handedOff)
        return (next.phase != .idle && !current.handedOff, !suppress && next.hasCameraFrames)
    }
}

struct RemoteFocusResult: Equatable, Sendable {
    let trackingStarted: Bool
    let polls: Int
    let timedOut: Bool
    var responseCode: UInt16 = PTPConstants.responseOK
    var endTrackingResponseCode: UInt16? = nil
    var trackingResponseCode: UInt16? = nil
    var moveResponseCode: UInt16? = nil
    var afStartResponseCode: UInt16? = nil
}

enum RemoteEvent: Sendable {
    case startRequested
    case deviceReady
    case frameReceived(fps: Double)
    case frameLost
    case captureRequested
    case captureConfirmed
    case recordingStarted
    case recordingStopped
    case operationFailed(String)
    case cancelled
    case disconnected
    case focusRequested(RemoteFocusPoint)
    case focusLocked
    case focusFailed
    case trackingEnded
    case recordingFailed(RemoteRecordingHint)
    case recordingHintDismissed
}

extension RemoteState {
    /// Pure reducer for the state transitions that are visible to the user.
    /// Transport side effects remain in the session coordinator.
    func applying(_ event: RemoteEvent) -> RemoteState {
        var next = self
        switch event {
        case .startRequested:
            next.session = .starting
            next.liveViewStable = false
            next.errorMessage = nil
        case .deviceReady:
            next.session = .warmingUp
            next.errorMessage = nil
        case let .frameReceived(frameRate):
            next.frameSequence &+= 1
            next.fps = frameRate
            next.session = .ready
            // A decoded image is display-ready; USB stability belongs to the
            // acquisition loop (eight successful packets, excluding Busy).
            next.errorMessage = nil
        case .frameLost:
            if next.session == .ready {
                next.session = .recovering
                next.liveViewStable = false
            }
        case .captureRequested:
            // Android keeps REC off while the start command is in flight.
            // Busy ownership lives in the recording operation gate.
            if !next.movieMode { next.capture = .capturing }
        case .captureConfirmed:
            if next.capture == .capturing { next.capture = .idle }
        case .recordingStarted:
            next.capture = .recording
        case .recordingStopped:
            next.capture = .idle
        case let .operationFailed(message):
            next.session = .failed(message)
            next.capture = .failed(message)
            next.errorMessage = message
            next.liveViewStable = false
        case .cancelled, .disconnected:
            next.session = .idle
            next.capture = .idle
            next.liveViewStable = false
            next.frameSequence = 0
            next.fps = 0
            next.errorMessage = nil
            next.recordingHint = nil
        case let .focusRequested(point):
            next.focus.phase = .focusing
            next.focus.point = point
            next.focus.nonce &+= 1
        case .focusLocked:
            next.focus.phase = .locked
            next.focus.tracking = next.focus.tracking
        case .focusFailed:
            next.focus.phase = .failed
            next.focus.tracking = false
        case .trackingEnded:
            next.focus.tracking = false
            if next.focus.phase == .locked { next.focus.phase = .idle }
        case let .recordingFailed(hint):
            // A failed stop must preserve the active recording. A failed
            // start likewise cannot override an authoritative camera event.
            next.recordingHint = hint
        case .recordingHintDismissed:
            next.recordingHint = nil
        }
        return next
    }
}

/// Android RemoteOrientationSession plus its conflated request slot. Generation
/// validation prevents an old stability timer from surviving pause/invalid input.
struct RemoteOrientationSession<Orientation: Equatable> {
    private(set) var candidate: Orientation?
    private var suppressed: Orientation?
    private var generation: UInt64 = 0
    private var pending: Orientation?

    mutating func observe(_ next: Orientation?) -> UInt64? {
        guard candidate != next else { return nil }
        candidate = next
        generation &+= 1
        guard let next, next != suppressed else { return nil }
        suppressed = nil
        return generation
    }
    func accepts(_ ticket: UInt64, target: Orientation) -> Bool {
        generation == ticket && candidate == target
    }
    mutating func pause() { candidate = nil; generation &+= 1 }
    mutating func suppressCurrent() { suppressed = candidate; generation &+= 1 }
    mutating func enqueue(_ target: Orientation) { pending = target }
    mutating func takePending() -> Orientation? {
        defer { pending = nil }
        return pending
    }
    mutating func discardPending() { pending = nil }
}
