import Foundation

/// Owns one PTP/IP command/event pair. The handshake is kept separate from
/// USB so switching modes cannot close the other mode's active session.
actor WiFiConnectionService {
    private var transport: PTPIPSocketTransport?
    private var repository: CameraRepository?

    func connect(host: String) async throws -> CameraRepository {
        if let repository { return repository }
        let socket = try await PTPIPSocketTransport.open(host: host)
        do {
            let session = PTPSession(transport: socket)
            let repo = CameraRepository(session: session)
            _ = try await session.execute(operation: PTPConstants.openSession, parameters: [1])
            _ = try await repo.loadDeviceInfo()
            transport = socket; repository = repo
            return repo
        } catch {
            socket.close()
            throw error
        }
    }

    func disconnect() {
        transport?.close()
        transport = nil
        repository = nil
    }
}
