import Foundation

struct SelectedUSBPTPTransport: PTPCommandTransport {
    let transport: ImageCaptureUSBTransport
    let deviceID: String

    func sendPTP(command: Data, data: Data?) async throws -> (response: Data, payload: Data) {
        try await transport.sendPTP(command: command, data: data, to: deviceID)
    }

    func cancelPTP(transactionID: UInt32) async -> Bool {
        // NikonCamera.abortActiveTransaction closes USB instead of attempting
        // IP Cancel/drain. Reuse the existing bounded ImageCapture close path.
        _ = try? await AsyncDeadline.run(nanoseconds: 2_000_000_000, timeoutError: PTPSessionError.timeout) {
            await transport.closeSession(for: deviceID)
        }
        return false
    }
}
