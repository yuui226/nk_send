import Foundation

struct SelectedUSBPTPTransport: PTPCommandTransport {
    let transport: ImageCaptureUSBTransport
    let deviceID: String
    let sessionToken: UUID

    /// ImageCaptureCore owns the physical PTP request and pauses that request
    /// when iOS suspends device communication in the background. Its callback
    /// (including ICReturnCommunicationTimedOut) is the authoritative timeout;
    /// an Android-style wall-clock read deadline would expire during suspension.
    var managesCommandTimeouts: Bool { true }

    func sendPTP(command: Data, data: Data?) async throws -> (response: Data, payload: Data) {
        try await transport.sendPTP(command: command, data: data, to: deviceID,
                                    expectedSessionToken: sessionToken)
    }

    func cancelPTP(transactionID: UInt32) async -> Bool {
        // ImageCaptureCore exposes no per-command PTP Cancel operation. The app
        // must never turn UI-task cancellation into an active camera disconnect;
        // framework-managed requests therefore drain their callback instead.
        return false
    }
}
