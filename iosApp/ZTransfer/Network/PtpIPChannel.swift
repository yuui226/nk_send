import Foundation
import ZTransferShared

enum PtpIPChannelError: Error, LocalizedError {
    case invalidHeader, payloadTooLarge, malformedAcknowledgement, unexpectedPacket(Int32)
    var errorDescription: String? {
        switch self {
        case .invalidHeader: return "相机返回了无效的 PTP/IP 包头。"
        case .payloadTooLarge: return "相机返回的数据超过当前操作的接收上限。"
        case .malformedAcknowledgement: return "相机握手响应不完整。"
        case .unexpectedPacket(let type): return "相机返回非预期的握手包：\(type)。"
        }
    }
}

struct PtpIPPacket {
    let type: Int32
    let payload: Data
}

/// Only Apple I/O and data bridging. Wire layout, limits and handshake encoding come from shared.
/// The byte-by-byte Kotlin bridge is used only for small headers/control messages; file payloads
/// remain Data and `readPacketPayload` passes bounded chunks directly to the sink.
actor PtpIPChannel {
    let stream: CameraTCPStream
    private var readingPacket = false

    init(stream: CameraTCPStream) { self.stream = stream }

    func readControlPacket(timeout: TimeInterval, maximumPayloadBytes: Int = 64 * 1024,
                           waitForPacket: Bool = false) async throws -> PtpIPPacket {
        var payload = Data()
        let type = try await readPacketPayload(timeout: timeout, maximumPayloadBytes: maximumPayloadBytes,
                                              waitForPacket: waitForPacket) {
            payload.append($0)
        }
        return PtpIPPacket(type: type, payload: payload)
    }

    /// Synchronous sink preserves backpressure; it executes on this actor, not MainActor.
    /// Sink failure or cancellation closes the stream instead of leaving a half-consumed packet.
    func readPacketPayload(
        timeout: TimeInterval,
        maximumPayloadBytes: Int,
        waitForPacket: Bool = false,
        resetTimeoutAfterChunk: Bool = false,
        inspectHeader: (Int32, Int) throws -> Void = { _, _ in },
        consume: (Data) throws -> Void
    ) async throws -> Int32 {
        guard !readingPacket else { throw CameraStreamError.operationInProgress }
        guard maximumPayloadBytes >= 0, timeout.isFinite, timeout > 0 else {
            throw CameraStreamError.invalidArgument
        }
        readingPacket = true
        defer { readingPacket = false }
        var deadline = ProcessInfo.processInfo.systemUptime + timeout
        func remainingTime() throws -> TimeInterval {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw CameraStreamError.timedOut }
            return remaining
        }
        do {
            let codec = PtpIpPacketCodec.shared
            // An event channel may legitimately stay silent. Only its first byte waits without
            // a deadline; a partial header/payload is still bounded, and cancellation closes it.
            var header = Data()
            if waitForPacket {
                header = try await stream.readExactly(1, timeout: nil)
                deadline = ProcessInfo.processInfo.systemUptime + timeout
            }
            let headerTail = try await stream.readExactly(Int(codec.HEADER_SIZE) - header.count, timeout: remainingTime())
            header.append(headerTail)
            let bytes = Self.kotlinBytes(header)
            let length = codec.readLength(bytes: bytes, offset: 0)
            guard codec.isValidLength(length: length) else { throw PtpIPChannelError.invalidHeader }
            var remaining = Int(length) - Int(codec.HEADER_SIZE)
            guard remaining <= maximumPayloadBytes else { throw PtpIPChannelError.payloadTooLarge }
            let type = codec.readType(bytes: bytes, offset: 0)
            try inspectHeader(type, remaining)
            while remaining > 0 {
                let chunk = try await stream.readExactly(min(remaining, 64 * 1024), timeout: remainingTime())
                try Task.checkCancellation()
                try consume(chunk)
                remaining -= chunk.count
                if resetTimeoutAfterChunk { deadline = ProcessInfo.processInfo.systemUptime + timeout }
            }
            return type
        } catch {
            stream.close()
            throw error
        }
    }

    func sendCommandHandshake(guid: Data, name: String, standard: Bool, timeout: TimeInterval) async throws {
        guard guid.count == 16, name.utf16.count <= 255 else { throw CameraStreamError.invalidArgument }
        let codec = PtpIpProtocolCodec.shared
        let bytes = Self.kotlinBytes(guid)
        let request = standard
            ? codec.encodeStandardInitCommandRequest(initiatorGuid: bytes, initiatorName: name)
            : codec.encodeLegacyInitCommandRequest(initiatorGuid: bytes, initiatorName: name)
        try await stream.write(Self.data(request), timeout: timeout)
    }

    func sendEventHandshake(connectionNumber: Int32, timeout: TimeInterval) async throws {
        let packet = PtpIpProtocolCodec.shared.encodeInitEventRequest(connectionNumber: connectionNumber)
        try await stream.write(Self.data(packet), timeout: timeout)
    }

    func sendCommand(operationCode: Int32, transactionId: Int32, parameters: [Int32], data: Data? = nil, timeout: TimeInterval) async throws {
        guard (0...0xFFFF).contains(operationCode), parameters.count <= 5, (data?.count ?? 0) <= 64 * 1024 else {
            throw CameraStreamError.invalidArgument
        }
        let values = KotlinIntArray(size: Int32(parameters.count))
        for (index, value) in parameters.enumerated() { values.set(index: Int32(index), value: value) }
        let packet: KotlinByteArray
        if let data {
            packet = PtpIpProtocolCodec.shared.encodeCommandWithData(operationCode: operationCode,
                transactionId: transactionId, data: Self.kotlinBytes(data), parameters: values)
        } else {
            packet = PtpIpProtocolCodec.shared.encodeCommandRequest(
                operationCode: operationCode, transactionId: transactionId, parameters: values)
        }
        try await stream.write(Self.data(packet), timeout: timeout)
    }

    func sendPong(timeout: TimeInterval) async throws {
        let packet = PtpIpPacketCodec.shared.encode(type: PtpConstants.shared.PONG, payload: nil)
        try await stream.write(Self.data(packet), timeout: timeout)
    }

    static func operationResponse(_ payload: Data) -> PtpIpOperationResponse? {
        PtpIpOperationCodec.shared.decodeResponse(payload: kotlinBytes(payload))
    }

    static func dataTransactionId(_ payload: Data) -> Int32? {
        let size = Int(PtpIpOperationCodec.shared.DATA_PREFIX_SIZE)
        return PtpIpOperationCodec.shared.decodeDataHeader(prefix: kotlinBytes(Data(payload.prefix(size))))?.transactionId
    }

    static func deviceInfo(_ payload: Data) -> LabDeviceInfo? {
        PtpIpOperationCodec.shared.decodeDeviceInfo(payload: kotlinBytes(payload))
    }

    static func identifiers(_ payload: Data) -> [Int32]? {
        guard let values = PtpIpOperationCodec.shared.decodeIdentifiers(payload: kotlinBytes(payload)) else { return nil }
        return (0..<Int(values.size)).map { values.get(index: Int32($0)) }
    }

    static func objectInfo(handle: Int32, payload: Data) -> PtpObjectInfo? {
        PtpIpOperationCodec.shared.decodeObjectInfo(handle: handle, payload: kotlinBytes(payload))
    }

    static func event(_ payload: Data) -> PtpIpEvent? {
        PtpIpProtocolCodec.shared.decodeEvent(payload: kotlinBytes(payload))
    }

    static func dataStart(_ payload: Data) -> PtpIpDataStart? {
        PtpTransferBridge.shared.decodeStart(payload: kotlinBytes(payload))
    }

    static func objectSize(_ payload: Data) -> Int64 {
        PtpTransferBridge.shared.objectSize(payload: kotlinBytes(payload))
    }

    func commandAcknowledgement(_ packet: PtpIPPacket) throws -> PtpIpInitCommandAck {
        guard packet.type == PtpConstants.shared.INIT_CMD_ACK else {
            throw PtpIPChannelError.unexpectedPacket(packet.type)
        }
        // The legacy decoder assumes >= 4 bytes. Check before crossing the Objective-C boundary
        // so malformed input cannot cause an unhandled Kotlin exception in Swift.
        guard packet.payload.count >= 4,
              let ack = PtpIpProtocolCodec.shared.decodeInitCommandAck(payload: Self.kotlinBytes(packet.payload)) else {
            throw PtpIPChannelError.malformedAcknowledgement
        }
        return ack
    }

    private static func kotlinBytes(_ data: Data) -> KotlinByteArray {
        let result = KotlinByteArray(size: Int32(data.count))
        for (index, value) in data.enumerated() { result.set(index: Int32(index), value: Int8(bitPattern: value)) }
        return result
    }

    private static func data(_ bytes: KotlinByteArray) -> Data {
        var result = Data(count: Int(bytes.size))
        for index in 0..<Int(bytes.size) { result[index] = UInt8(bitPattern: bytes.get(index: Int32(index))) }
        return result
    }
}
