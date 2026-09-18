import Foundation
import Darwin
import Network
import XCTest
#if SWIFT_PACKAGE
@testable import ZTransferProtocol
#else
@testable import ZTransfer
#endif

@MainActor
final class PTPIPPOSIXChannelTests: XCTestCase {
    func testSocketTimeoutRoundsUpWithoutAccidentallyDisablingDeadline() {
        for nanoseconds: UInt64 in [0, 1, 999, 1000] {
            let timeout = PTPIPPOSIXChannel.receiveTimeout(nanoseconds: nanoseconds)
            XCTAssertEqual(timeout.tv_sec, 0)
            XCTAssertEqual(timeout.tv_usec, 1)
        }
        let minute = PTPIPPOSIXChannel.receiveTimeout(nanoseconds: 60_000_000_000)
        XCTAssertEqual(minute.tv_sec, 60)
        XCTAssertEqual(minute.tv_usec, 0)
        let fractional = PTPIPPOSIXChannel.receiveTimeout(nanoseconds: 1_000_000_001)
        XCTAssertEqual(fractional.tv_sec, 1)
        XCTAssertEqual(fractional.tv_usec, 1)
    }

    func testSocketReadTimeoutRestoresUnlimitedEventStyleRead() async throws {
        let peer = try await SocketEchoPeer.start()
        defer { peer.close() }
        let channel = try await PTPIPPOSIXChannel.connect(host: "127.0.0.1", port: peer.port, isCommandChannel: false)
        defer { channel.close() }
        do {
            _ = try await channel.receive(readTimeoutNanoseconds: 30_000_000)
            XCTFail("Expected timeout without data")
        } catch { XCTAssertEqual(error as? PTPSessionError, .timeout) }
        let sender = Task {
            try await Task.sleep(nanoseconds: 150_000_000)
            try await channel.send(Data([1, 2, 3]))
        }
        defer { sender.cancel() }
        let received = try await channel.receive()
        try await sender.value
        XCTAssertEqual(received, Data([1, 2, 3]))
    }
    func testBorrowedPacketStorageIsReusedAndOwningFallbackIsIndependent() throws {
        let first = Data(repeating: 3, count: 65553)
        let second = Data(repeating: 7, count: 65553)
        let wire = try PTPIPCodec.encode(type: .data, payload: first) + PTPIPCodec.encode(type: .endData, payload: second)
        let reader = PTPIPPOSIXPacketReader()
        let source = PacketByteSource(wire, maximum: 7)
        var address: UInt = 0
        var retained = Data()
        try reader.withPacket(receive: source.read) { type, bytes in
            XCTAssertEqual(type, .data)
            XCTAssertEqual(Data(bytes), first)
            address = UInt(bitPattern: bytes.baseAddress!)
            retained = Data(bytes) // Explicit ownership, never retain the pointer.
        }
        try reader.withPacket(receive: source.read) { type, bytes in
            XCTAssertEqual(type, .endData)
            XCTAssertEqual(UInt(bitPattern: bytes.baseAddress!), address)
            XCTAssertEqual(Data(bytes), second)
        }
        XCTAssertEqual(retained, first)
    }

    func testBorrowedConsumerFailurePreservesReadAheadAndReaderStorage() throws {
        enum Failure: Error { case sink }
        let first = try PTPIPCodec.encode(type: .data, payload: Data(repeating: 3, count: 32))
        let response = try PTPIPCodec.encode(type: .commandResponse, payload: Data([1, 0x20, 1, 0, 0, 0]))
        let reader = PTPIPPOSIXPacketReader()
        let source = PacketByteSource(first + response)
        XCTAssertThrowsError(try reader.withPacket(receive: source.read) { _, _ in throw Failure.sink })
        let remaining = reader.takeRemaining()
        XCTAssertEqual(remaining, response)
        reader.seed(remaining)
        XCTAssertEqual(try reader.readPacket(receive: source.read).type, .commandResponse)
        XCTAssertEqual(source.calls, 1)
    }

    func testLargePacketReadsDirectlyIntoBodyLikeAndroidBufferedInputStream() throws {
        let payload = Data(repeating: 0xA3, count: 1024 * 1024 + 5)
        let packet = try PTPIPCodec.encode(type: .data, payload: payload)
        let tail = try PTPIPCodec.encode(type: .pong)
        let reader = PTPIPPOSIXPacketReader()
        reader.seed(Data(packet.prefix(8)))
        let source = PacketByteSource(Data(packet.dropFirst(8)) + tail, maximum: Int.max)
        XCTAssertEqual(try reader.readPacket(receive: source.read).payload, payload)
        XCTAssertEqual(source.requestedLengths, [payload.count])
        XCTAssertEqual(try reader.readPacket(receive: source.read).type, .pong)
        XCTAssertEqual(source.requestedLengths, [payload.count, 64 * 1024])
        XCTAssertTrue(reader.takeRemaining().isEmpty)
    }

    func testEventChannelKeepsAndroidDefaultSocketOptions() async throws {
        let peer = try await SocketEchoPeer.start()
        defer { peer.close() }
        let channel = try await PTPIPPOSIXChannel.connect(host: "127.0.0.1", port: peer.port,
                                                         isCommandChannel: false)
        defer { channel.close() }
        XCTAssertEqual(channel.diagnosticSnapshot()?["tcp_no_delay"], 0)
        XCTAssertEqual(channel.diagnosticSnapshot()?["tcp_send_more_acks"], 0)
        try await channel.send(Data([4, 5]))
        let received = try await channel.receive()
        XCTAssertEqual(received, Data([4, 5]))
    }

    func testPacketReaderReturnsNetworkReadAheadBeforeNextOwner() throws {
        let first = try PTPIPCodec.encode(type: .data, payload: Data([1, 2, 3]))
        let next = try PTPIPCodec.encode(type: .commandResponse, payload: Data([1, 0x20, 1, 0, 0, 0]))
        let reader = PTPIPPOSIXPacketReader()
        let source = PacketByteSource(first + next)
        XCTAssertEqual(try reader.readPacket(receive: source.read).payload, Data([1, 2, 3]))
        let remaining = reader.takeRemaining()
        XCTAssertEqual(remaining, next)
        XCTAssertEqual(source.calls, 1)
        reader.seed(remaining)
        XCTAssertEqual(try reader.readPacket(receive: source.read).type, .commandResponse)
        XCTAssertEqual(source.calls, 1)
        XCTAssertTrue(reader.takeRemaining().isEmpty)
    }

    func testPacketReaderHandlesSplitHeaderBodyAndRetainedPackets() throws {
        let payloads = [Data([1, 2, 3]), Data(repeating: 0xA5, count: 65553), Data([9])]
        let wire = try payloads.reduce(into: Data()) { $0.append(try PTPIPCodec.encode(type: .data, payload: $1)) }
        let reader = PTPIPPOSIXPacketReader()
        reader.seed(Data(wire.prefix(3)))
        let source = PacketByteSource(Data(wire.dropFirst(3)), maximum: 7)
        var retained: [PTPIPPacket] = []
        for _ in payloads { retained.append(try reader.readPacket(receive: source.read)) }
        XCTAssertEqual(retained.map(\.payload), payloads)
        XCTAssertTrue(reader.takeRemaining().isEmpty)
        XCTAssertGreaterThan(source.calls, 9000)
    }

    func testPacketReaderPreservesReadAheadAcrossOwnersAndReusesAfterGrowth() throws {
        let first = try PTPIPCodec.encode(type: .data, payload: Data(repeating: 3, count: 1024 * 1024 + 5))
        let tail = try PTPIPCodec.encode(type: .commandResponse, payload: Data([1, 0x20, 1, 0, 0, 0]))
        let reader = PTPIPPOSIXPacketReader()
        reader.seed(first + tail)
        let noNetwork = PacketByteSource(Data())
        let retained = try reader.readPacket(receive: noNetwork.read)
        XCTAssertEqual(retained.payload.count, 1024 * 1024 + 5)
        XCTAssertEqual(reader.takeRemaining(), tail)
        reader.seed(try PTPIPCodec.encode(type: .data, payload: Data([8])))
        XCTAssertEqual(try reader.readPacket(receive: noNetwork.read).payload, Data([8]))
        XCTAssertEqual(retained.payload, Data(repeating: 3, count: 1024 * 1024 + 5))
        XCTAssertEqual(noNetwork.calls, 0)
    }

    func testPacketReaderRejectsInvalidLengthsAndTruncatedBody() throws {
        for length: UInt32 in [7, UInt32(PTPIPCodec.maxPacketLength + 1)] {
            let reader = PTPIPPOSIXPacketReader()
            let header = withUnsafeBytes(of: length.littleEndian) { Data($0) } + Data([10, 0, 0, 0])
            reader.seed(header)
            let source = PacketByteSource(Data())
            XCTAssertThrowsError(try reader.readPacket(receive: source.read)) {
                XCTAssertEqual($0 as? PTPIPCodecError, .malformedLength)
            }
            XCTAssertEqual(source.calls, 0)
        }
        let reader = PTPIPPOSIXPacketReader()
        let wire = try PTPIPCodec.encode(type: .data, payload: Data([1, 2, 3]))
        let source = PacketByteSource(Data(wire.dropLast()), maximum: 1)
        XCTAssertThrowsError(try reader.readPacket(receive: source.read)) {
            XCTAssertEqual($0 as? PTPIPPOSIXChannel.ChannelError, .closed)
        }
    }

    func testBulkEchoPreservesBytesAndConfiguresKernelBuffer() async throws {
        let peer = try await SocketEchoPeer.start()
        defer { peer.close() }
        let channel = try await PTPIPPOSIXChannel.connect(host: "127.0.0.1", port: peer.port, localAddress: "127.0.0.1")
        defer { channel.close() }
        XCTAssertGreaterThanOrEqual(channel.receiveBufferBytes, 4 * 1024 * 1024)
        let before = try XCTUnwrap(channel.diagnosticSnapshot())
        XCTAssertEqual(before["tcp_no_delay"], 1)
        XCTAssertGreaterThan(try XCTUnwrap(before["tcp_receive_window_bytes"]), 0)
        XCTAssertGreaterThan(try XCTUnwrap(before["tcp_max_segment_bytes"]), 0)
        let payload = Data((0..<(2 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
        let sender = Task { try await channel.send(payload) }
        var received = Data()
        while received.count < payload.count {
            let chunk = try await channel.receive()
            XCTAssertLessThanOrEqual(chunk.count, 64 * 1024)
            received.append(chunk)
        }
        try await sender.value
        XCTAssertEqual(received, payload)
        let after = try XCTUnwrap(channel.diagnosticSnapshot())
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(after["tcp_rx_bytes_total"]) - XCTUnwrap(before["tcp_rx_bytes_total"]), Double(payload.count))
        channel.close()
        XCTAssertNil(channel.diagnosticSnapshot())
    }

    func testShortReadDoesNotWaitForRequestedMaximum() async throws {
        let peer = try await SocketEchoPeer.start()
        defer { peer.close() }
        let channel = try await PTPIPPOSIXChannel.connect(host: "127.0.0.1", port: peer.port)
        defer { channel.close() }
        try await channel.send(Data([1, 2, 3]))
        let received = try await channel.receive(maximumLength: 65536)
        XCTAssertEqual(received, Data([1, 2, 3]))
    }

    func testSTACommandDarwinACKAdaptationPreservesData() async throws {
        let peer = try await SocketEchoPeer.start()
        defer { peer.close() }
        let channel = try await PTPIPPOSIXChannel.connect(host: "127.0.0.1", port: peer.port)
        defer { channel.close() }
        XCTAssertEqual(channel.diagnosticSnapshot()?["tcp_send_more_acks"], 1)
        try await channel.send(Data([1, 2, 3]))
        let received = try await channel.receive()
        XCTAssertEqual(received, Data([1, 2, 3]))
    }

    func testCallerCancellationDoesNotCloseAcceptedSocket() async throws {
        let peer = try await SocketEchoPeer.start()
        defer { peer.close() }
        let channel = try await PTPIPPOSIXChannel.connect(host: "127.0.0.1", port: peer.port)
        defer { channel.close() }
        let receiver = Task { try await channel.receive() }
        receiver.cancel()
        try await channel.send(Data([7]))
        let bytes = try await receiver.value
        XCTAssertEqual(bytes, Data([7]))
        try await channel.send(Data([8]))
        let next = try await channel.receive()
        XCTAssertEqual(next, Data([8]))
    }

    func testCloseWakesActiveReadAndRejectsQueuedRead() async throws {
        let peer = try await SocketEchoPeer.start()
        defer { peer.close() }
        let channel = try await PTPIPPOSIXChannel.connect(host: "127.0.0.1", port: peer.port)
        let first = Task { try await channel.receive() }
        let second = Task { try await channel.receive() }
        try await Task.sleep(for: .milliseconds(20))
        channel.close()
        channel.close()
        for task in [first, second] {
            do { _ = try await task.value; XCTFail("Closed socket read succeeded") }
            catch { XCTAssertEqual(error as? PTPIPPOSIXChannel.ChannelError, .closed) }
        }
        do { try await channel.send(Data([1])); XCTFail("Closed socket write succeeded") }
        catch { XCTAssertEqual(error as? PTPIPPOSIXChannel.ChannelError, .closed) }
    }

    func testInvalidRouteDoesNotFallBackToAnotherInterface() async throws {
        do {
            _ = try await PTPIPPOSIXChannel.connect(host: "127.0.0.1", port: 15740, localAddress: "not-an-ip")
            XCTFail("Invalid bind address accepted")
        } catch { XCTAssertEqual(error as? PTPIPPOSIXChannel.ChannelError, .invalidAddress) }
    }

    func testUnavailableLocalAddressFailsInsteadOfChangingRoute() async throws {
        let peer = try await SocketEchoPeer.start()
        defer { peer.close() }
        do {
            _ = try await PTPIPPOSIXChannel.connect(host: "127.0.0.1", port: peer.port, localAddress: "192.0.2.123")
            XCTFail("Unavailable local bind address was ignored")
        } catch { XCTAssertEqual(error as? PTPIPPOSIXChannel.ChannelError, .system(EADDRNOTAVAIL)) }
    }
}

private final class PacketByteSource {
    private let bytes: Data
    private let maximum: Int
    private var offset = 0
    private(set) var calls = 0
    private(set) var requestedLengths: [Int] = []
    init(_ bytes: Data, maximum: Int = 65536) { self.bytes = bytes; self.maximum = maximum }
    func read(_ target: UnsafeMutableRawBufferPointer) -> Int {
        calls += 1
        requestedLengths.append(target.count)
        let count = min(maximum, target.count, bytes.count - offset)
        if count > 0 {
            bytes.withUnsafeBytes { source in
                target.baseAddress!.copyMemory(from: source.baseAddress!.advanced(by: offset), byteCount: count)
            }
            offset += count
        }
        return count
    }
}

private final class SocketEchoPeer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ztransfer.tests.posix.peer")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    var port: UInt16 { listener.port!.rawValue }

    private init() throws { listener = try NWListener(using: .tcp, on: .any) }

    static func start() async throws -> SocketEchoPeer {
        let peer = try SocketEchoPeer()
        peer.listener.newConnectionHandler = { [weak peer] connection in
            guard let peer else { connection.cancel(); return }
            peer.lock.withLock { peer.connections.append(connection) }
            connection.start(queue: peer.queue)
            peer.receive(connection)
        }
        peer.listener.start(queue: peer.queue)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while peer.listener.port == nil || peer.listener.port?.rawValue == 0 {
            guard ContinuousClock.now < deadline else { peer.close(); throw PTPIPPOSIXChannel.ChannelError.timeout }
            try await Task.sleep(for: .milliseconds(1))
        }
        return peer
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] bytes, _, complete, error in
            guard let self else { return }
            guard error == nil, let bytes, !bytes.isEmpty else { connection.cancel(); return }
            connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
                if error != nil || complete { connection.cancel() }
                else { self?.receive(connection) }
            })
        }
    }

    func close() {
        listener.cancel()
        lock.withLock { connections.forEach { $0.cancel() }; connections.removeAll() }
    }
}
