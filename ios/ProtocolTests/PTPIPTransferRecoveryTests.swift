import Foundation
import Network
import XCTest
#if SWIFT_PACKAGE
@testable import ZTransferProtocol
#else
@testable import ZTransfer
#endif

@MainActor
final class PTPIPTransferRecoveryTests: XCTestCase {
    func testDownloadTimeoutRenewsDuringAPartiallyReceivedDataPacket() async throws {
        let peer = try PTPIPRecoveryPeer(behavior: .slowTransfer)
        let transport = try await peer.connect()
        defer { transport.close(); peer.close() }
        let session = PTPSession(transport: transport)
        let received = ReceivedBytes()
        let result = try await session.executeReceiving(operation: PTPConstants.getObject, parameters: [12],
                                                        sink: received.sink, timeoutNanoseconds: 250_000_000)
        XCTAssertEqual(result.code, PTPConstants.responseOK)
        XCTAssertEqual(result.receivedByteCount, 8)
        XCTAssertEqual(received.bytes, Data(1...8))
        XCTAssertTrue(peer.cancelledTransactions.isEmpty)
    }

    func testSizeProbeTimeoutUsesDownloadRecoveryBeforeNextCommand() async throws {
        let peer = try PTPIPRecoveryPeer(behavior: .cancel)
        let transport = try await peer.connect()
        defer { transport.close(); peer.close() }
        let session = PTPSession(transport: transport)
        do {
            _ = try await session.executeReceivingBuffered(operation: PTPConstants.getObjectSize, parameters: [12],
                                                            timeoutNanoseconds: 30_000_000)
            XCTFail("Expected size probe timeout")
        } catch { XCTAssertEqual(error as? PTPSessionError, .timeout) }
        let next = try await session.execute(operation: PTPConstants.getDeviceInfo)
        XCTAssertEqual(next.transactionID, 2)
        XCTAssertEqual(peer.cancelledTransactions, [1])
    }

    func testCancellationSendsCancelDrainsPingAndDataBeforeReusingSocket() async throws {
        try await checkCancellation(behavior: .cancel)
    }

    func testDrainMayLastLongerThanThreeSecondsWhileDataKeepsArriving() async throws {
        try await checkCancellation(behavior: .slowDrain)
    }

    private func checkCancellation(behavior: PTPIPRecoveryPeer.Behavior) async throws {
        let peer = try PTPIPRecoveryPeer(behavior: behavior)
        let transport = try await peer.connect()
        defer { transport.close(); peer.close() }
        let received = ReceivedBytes()
        let session = PTPSession(transport: transport)
        let call = Task {
            try await session.executeReceiving(operation: PTPConstants.getObject, parameters: [12], sink: received.sink)
        }
        try await waitUntil { received.started }
        let queued = Task { try await session.execute(operation: PTPConstants.getDeviceInfo) }
        call.cancel()
        do { _ = try await call.value; XCTFail("Cancelled download succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        let next = try await queued.value
        XCTAssertEqual(next.transactionID, 2)
        XCTAssertEqual(received.bytes, Data())
        XCTAssertEqual(peer.cancelledTransactions, [1])
        XCTAssertEqual(peer.pongCount, 1)
    }

    func testWriteFailureDrainsAndPreservesOriginalErrorAndNextCommand() async throws {
        let peer = try PTPIPRecoveryPeer(behavior: .writeFailure)
        let transport = try await peer.connect()
        defer { transport.close(); peer.close() }
        let session = PTPSession(transport: transport)
        let sink = PTPDataSink(started: { _ in }, received: { _ in throw WriteFailure.diskFull })
        do {
            _ = try await session.executeReceiving(operation: PTPConstants.getObject, parameters: [12], sink: sink)
            XCTFail("Write failure was lost")
        } catch { XCTAssertEqual(error as? WriteFailure, .diskFull) }
        let next = try await session.execute(operation: PTPConstants.getDeviceInfo)
        XCTAssertEqual(next.transactionID, 2)
        XCTAssertEqual(peer.cancelledTransactions, [1])
    }

    func testSilentCameraAfterCancelTimesOutAndRetiresSession() async throws {
        let peer = try PTPIPRecoveryPeer(behavior: .silent)
        let transport = try await peer.connect()
        defer { transport.close(); peer.close() }
        let session = PTPSession(transport: transport)
        let received = ReceivedBytes()
        let call = Task {
            try await session.executeReceiving(operation: PTPConstants.getObject, parameters: [12], sink: received.sink)
        }
        try await waitUntil { received.started }
        let start = ContinuousClock.now
        call.cancel()
        do { _ = try await call.value; XCTFail("Cancelled download succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .seconds(3))
        XCTAssertLessThan(start.duration(to: .now), .seconds(5))
        do { _ = try await session.execute(operation: PTPConstants.getDeviceInfo); XCTFail("Retired channel reused") }
        catch { XCTAssertEqual(error as? PTPSessionError, .invalidated) }
        XCTAssertEqual(peer.cancelledTransactions, [1])
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw PTPSessionError.timeout }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private enum WriteFailure: Error { case diskFull }
}

private final class ReceivedBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var data = Data()
    var started: Bool { lock.withLock { didStart } }
    var bytes: Data { lock.withLock { data } }
    var sink: PTPDataSink {
        PTPDataSink(started: { [self] _ in lock.withLock { didStart = true } },
                    received: { [self] bytes in lock.withLock { data.append(bytes) } })
    }
}

/// A local command/event peer exercises the production NWConnection transport,
/// including the Cancel packet actually sent on the command socket. It serves
/// only packets prescribed by NikonCamera.abortActiveTransaction; no camera
/// samples or changes to Android are required.
private final class PTPIPRecoveryPeer: @unchecked Sendable {
    enum Behavior: Sendable { case cancel, writeFailure, slowDrain, silent, slowTransfer }
    private let behavior: Behavior
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ztransfer.tests.ptpip.recovery")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var tasks: [Task<Void, Never>] = []
    private var cancels: [UInt32] = []
    private var pongs = 0
    var cancelledTransactions: [UInt32] { lock.withLock { cancels } }
    var pongCount: Int { lock.withLock { pongs } }

    init(behavior: Behavior) throws {
        self.behavior = behavior
        listener = try NWListener(using: .tcp, on: .any)
    }

    func connect() async throws -> PTPIPSocketTransport {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: queue)
            let task = Task { [weak self] in
                do { try await self?.serve(connection) } catch { connection.cancel() }
            }
            lock.withLock { connections.append(connection); tasks.append(task) }
        }
        listener.start(queue: queue)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while listener.port == nil || listener.port?.rawValue == 0 {
            guard ContinuousClock.now < deadline else { close(); throw PTPSessionError.timeout }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        return try await PTPIPSocketTransport.open(host: "127.0.0.1", port: listener.port!.rawValue,
                                                  connectionParameters: .tcp)
    }

    func close() {
        listener.cancel()
        let (connections, tasks) = lock.withLock {
            let result = (self.connections, self.tasks)
            self.connections.removeAll(); self.tasks.removeAll()
            return result
        }
        tasks.forEach { $0.cancel() }
        connections.forEach { $0.cancel() }
    }

    private func serve(_ connection: NWConnection) async throws {
        while !Task.isCancelled {
            let packet = try await readPacket(connection)
            switch packet.type {
            case .initCommandRequest:
                try await send(.initCommandAck, payload: littleEndian(UInt32(1)), on: connection)
            case .initEventRequest:
                try await send(.initEventAck, on: connection)
            case .commandRequest:
                let operation = UInt16(packet.payload[4]) | UInt16(packet.payload[5]) << 8
                let transaction = uint32(packet.payload, at: 6)
                if operation == PTPConstants.getObject || operation == PTPConstants.getObjectSize {
                    try await send(.startData, payload: littleEndian(transaction) + littleEndian(UInt64(256)), on: connection)
                    if behavior == .writeFailure {
                        try await send(.data, payload: littleEndian(transaction) + Data([1, 2, 3]), on: connection)
                    } else if behavior == .slowTransfer {
                        let dataPacket = try PTPIPCodec.encode(type: .data, payload: littleEndian(transaction) + Data(1...8))
                        try await sendBytes(Data(dataPacket.prefix(12)), on: connection)
                        for offset in stride(from: 12, to: dataPacket.count, by: 2) {
                            try await Task.sleep(nanoseconds: 100_000_000)
                            try await sendBytes(dataPacket.subdata(in: offset..<(offset + 2)), on: connection)
                        }
                        try await send(.commandResponse, payload: littleEndian(PTPConstants.responseOK) + littleEndian(transaction), on: connection)
                    }
                } else {
                    try await send(.commandResponse, payload: littleEndian(PTPConstants.responseOK) + littleEndian(transaction), on: connection)
                }
            case .cancel:
                let transaction = uint32(packet.payload, at: 0)
                lock.withLock { cancels.append(transaction) }
                if behavior == .silent { continue }
                try await send(.ping, on: connection)
                let pong = try await readPacket(connection)
                guard pong.type == .pong else { throw PTPSessionError.invalidResponse }
                lock.withLock { pongs += 1 }
                for _ in 0..<(behavior == .slowDrain ? 4 : 1) {
                    if behavior == .slowDrain { try await Task.sleep(nanoseconds: 1_000_000_000) }
                    try await send(.data, payload: littleEndian(transaction) + Data([99, 98]), on: connection)
                }
                try await send(.endData, payload: littleEndian(transaction), on: connection)
                try await send(.commandResponse, payload: littleEndian(UInt16(0x201F)) + littleEndian(transaction), on: connection)
            default: throw PTPSessionError.invalidResponse
            }
        }
    }

    private func readPacket(_ connection: NWConnection) async throws -> PTPIPPacket {
        let header = try await read(8, on: connection)
        let count = Int(uint32(header, at: 0))
        guard count >= 8, count <= PTPIPCodec.maxPacketLength else { throw PTPIPCodecError.malformedLength }
        let payload = try await read(count - 8, on: connection)
        return try PTPIPCodec.decode(header + payload)
    }

    private func read(_ count: Int, on connection: NWConnection) async throws -> Data {
        var data = Data()
        while data.count < count {
            let remaining = count - data.count
            let chunk = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { content, _, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let content, !content.isEmpty { continuation.resume(returning: content) }
                    else { continuation.resume(throwing: PTPSessionError.invalidated) }
                }
            }
            data.append(chunk)
        }
        return data
    }

    private func send(_ type: PTPIPPacketType, payload: Data = Data(), on connection: NWConnection) async throws {
        let packet = try PTPIPCodec.encode(type: type, payload: payload)
        try await sendBytes(packet, on: connection)
    }

    private func sendBytes(_ packet: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: packet, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private func uint32(_ data: Data, at index: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(data[index + $1]) << ($1 * 8) }
    }
}
