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

struct RemoteFocusResult: Equatable, Sendable {
    let trackingStarted: Bool
    let polls: Int
    let timedOut: Bool
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
            next.liveViewStable = true
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
