import Foundation

struct SelectedUSBPTPTransport: PTPCommandTransport {
    let transport: ImageCaptureUSBTransport
    let deviceID: String

    func sendPTP(command: Data, data: Data?) async throws -> (response: Data, payload: Data) {
        try await transport.sendPTP(command: command, data: data, to: deviceID)
    }
}
