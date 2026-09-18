import Foundation
import Darwin

typealias PTPIPBorrowedPacketConsumer = (PTPIPPacketType, UnsafeRawBufferPointer) throws -> Void
typealias PTPIPBorrowedPacketRead = (PTPIPBorrowedPacketConsumer) throws -> Void

/// STA byte channel matching NikonCamera.connectSta's Android socket setup.
/// Shared by Debug/Release; AP keeps its existing Network.framework path.
/// Blocking syscalls run on dedicated queues, never Swift executors.
final class PTPIPPOSIXChannel: @unchecked Sendable {
    enum ChannelError: Error, Equatable {
        case system(Int32)
        case invalidAddress
        case closed
        case timeout
    }

    private let lock = NSLock()
    private let readQueue = DispatchQueue(label: "com.ztransfer.ptpip.posix.read", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "com.ztransfer.ptpip.posix.write", qos: .userInitiated)
    private var descriptor: Int32
    private var closed = false
    private var activeOperations = 0
    // Accessed only on readQueue. Borrowed download callbacks consume storage
    // synchronously; owning adapters explicitly copy before the next packet.
    private var packetReader: PTPIPPOSIXPacketReader?
    let receiveBufferBytes: Int

    private init(descriptor: Int32, receiveBufferBytes: Int) {
        self.descriptor = descriptor
        self.receiveBufferBytes = receiveBufferBytes
    }

    deinit { close() }

    /// Public Darwin TCP_CONNECTION_INFO, sampled only at diagnostic checkpoints.
    /// Send-side congestion/retransmit values describe this phone, not the camera.
    /// Keep the descriptor locked during getsockopt so close cannot recycle it.
    func diagnosticSnapshot() -> [String: Double]? {
        lock.withLock {
            guard !closed, descriptor >= 0 else { return nil }
            var info = tcp_connection_info()
            var length = socklen_t(MemoryLayout.size(ofValue: info))
            guard getsockopt(descriptor, IPPROTO_TCP, TCP_CONNECTION_INFO, &info, &length) == 0,
                  length == MemoryLayout.size(ofValue: info) else { return nil }
            var fields: [String: Double] = [
                "tcp_receive_window_bytes": Double(info.tcpi_rcv_wnd),
                "tcp_receive_window_scale": Double(info.tcpi_rcv_wscale),
                "tcp_max_segment_bytes": Double(info.tcpi_maxseg),
                "tcp_options": Double(info.tcpi_options),
                "tcp_flags": Double(info.tcpi_flags),
                "tcp_local_srtt_ms": Double(info.tcpi_srtt),
                "tcp_rx_bytes_total": Double(info.tcpi_rxbytes),
                "tcp_rx_packets_total": Double(info.tcpi_rxpackets),
                "tcp_rx_out_of_order_bytes_total": Double(info.tcpi_rxoutoforderbytes),
                "tcp_local_tx_retransmit_bytes_total": Double(info.tcpi_txretransmitbytes),
            ]
            var moreACKs: Int32 = 0
            length = socklen_t(MemoryLayout.size(ofValue: moreACKs))
            if getsockopt(descriptor, IPPROTO_TCP, TCP_SENDMOREACKS, &moreACKs, &length) == 0 {
                fields["tcp_send_more_acks"] = Double(moreACKs)
            }
            var noDelay: Int32 = 0
            length = socklen_t(MemoryLayout.size(ofValue: noDelay))
            if getsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &noDelay, &length) == 0 {
                // Darwin may return a nonzero flag mask, not the literal 1.
                fields["tcp_no_delay"] = noDelay == 0 ? 0 : 1
            }
            return fields
        }
    }

    static func connect(host: String, port: UInt16, localAddress: String? = nil,
                        isCommandChannel: Bool = true,
                        timeout: Duration = .seconds(3)) async throws -> PTPIPPOSIXChannel {
        // STA discovery produces numeric IPv4 addresses; do not silently fall
        // back to DNS or a different route if the selected address is invalid.
        let remote = try address(host, port: port)
        let local = try localAddress.map { try address($0, port: 0) }
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw ChannelError.system(errno) }
        let channel: PTPIPPOSIXChannel
        do {
            try setOption(fd, level: SOL_SOCKET, name: SO_NOSIGPIPE, value: 1)
            if isCommandChannel {
                try setOption(fd, level: IPPROTO_TCP, name: TCP_NODELAY, value: 1)
                // Android configures only the command socket, before connect.
                // Event traffic retains the kernel defaults, as in connectSta.
                try setOption(fd, level: SOL_SOCKET, name: SO_RCVBUF, value: 4 * 1024 * 1024)
                // Equal application defaults do not make Linux and Darwin's
                // delayed ACK policies equal. Keep the public Darwin adapter
                // on STA command sockets, in both build configurations.
                // Default-policy device samples regressed to 1.28–1.35 MiB/s;
                // earlier adapted samples were 1.5–1.8, still below Android.
                // This is not a claim that ACKs explain the remaining gap.
                // See STA下载-Android与iOS实现差异审查.md, device acceptance.
                try setOption(fd, level: IPPROTO_TCP, name: TCP_SENDMOREACKS, value: 1)
            }
            var actual: Int32 = 0
            var length = socklen_t(MemoryLayout.size(ofValue: actual))
            guard getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &actual, &length) == 0 else {
                throw ChannelError.system(errno)
            }
            channel = PTPIPPOSIXChannel(descriptor: fd, receiveBufferBytes: Int(actual))
        } catch {
            Darwin.close(fd)
            throw error
        }
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try await channel.onQueue(channel.writeQueue) { fd in
                    if let local {
                        let result = withSockaddr(local) { Darwin.bind(fd, $0, $1) }
                        guard result == 0 else { throw ChannelError.system(errno) }
                    }
                    let flags = fcntl(fd, F_GETFL)
                    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                        throw ChannelError.system(errno)
                    }
                    let result = withSockaddr(remote) { Darwin.connect(fd, $0, $1) }
                    if result != 0 {
                        guard errno == EINPROGRESS else { throw ChannelError.system(errno) }
                        let deadline = ContinuousClock.now.advanced(by: timeout)
                        while true {
                            guard !channel.isClosed else { throw ChannelError.closed }
                            let remaining = ContinuousClock.now.duration(to: deadline)
                            guard remaining > .zero else { throw ChannelError.timeout }
                            let parts = remaining.components
                            let ms = min(Double(Int32.max), ceil(Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15))
                            var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                            let ready = Darwin.poll(&pollFD, 1, Int32(ms))
                            if ready == 0 { throw ChannelError.timeout }
                            if ready < 0 {
                                if errno == EINTR { continue }
                                throw ChannelError.system(errno)
                            }
                            var socketError: Int32 = 0
                            var length = socklen_t(MemoryLayout.size(ofValue: socketError))
                            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
                                throw ChannelError.system(errno)
                            }
                            guard socketError == 0 else { throw ChannelError.system(socketError) }
                            break
                        }
                    }
                    guard fcntl(fd, F_SETFL, flags) == 0 else { throw ChannelError.system(errno) }
                }
                try Task.checkCancellation()
                guard !channel.isClosed else { throw ChannelError.closed }
                return channel
            } catch {
                channel.close()
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            // Only an unaccepted connection attempt is caller-owned.
            channel.close()
        }
    }

    func receive(maximumLength: Int = 64 * 1024, diagnostics: PTPTransferDiagnostics? = nil,
                 readTimeoutNanoseconds: UInt64? = nil) async throws -> Data {
        precondition(maximumLength > 0)
        let queuedAt = diagnostics.map { _ in ContinuousClock.now }
        let (bytes, queueMS, syscallMS, workerOtherMS, finishedAt) = try await onQueue(readQueue) { fd in
            let previous = try readTimeoutNanoseconds.map { try Self.installReceiveTimeout(fd, nanoseconds: $0) }
            defer { if let previous { Self.restoreReceiveTimeout(fd, previous) } }
            let workerStarted = queuedAt.map { _ in ContinuousClock.now }
            let queueMS = queuedAt.map { PTPTransferDiagnostics.milliseconds(since: $0) } ?? 0
            var bytes = Data(count: min(maximumLength, 64 * 1024))
            var syscallMS = 0.0
            while true {
                let syscallStarted = queuedAt.map { _ in ContinuousClock.now }
                let count = bytes.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
                // Save errno before clock/diagnostic helpers call any APIs.
                let readError = count < 0 ? errno : 0
                if let syscallStarted { syscallMS += PTPTransferDiagnostics.milliseconds(since: syscallStarted) }
                if count < 0 {
                    if readError == EINTR { continue }
                    if readError == EAGAIN || readError == EWOULDBLOCK { throw PTPSessionError.timeout }
                    throw ChannelError.system(readError)
                }
                guard count > 0 else { throw ChannelError.closed }
                bytes.removeSubrange(count..<bytes.count)
                let workerMS = workerStarted.map { PTPTransferDiagnostics.milliseconds(since: $0) } ?? 0
                return (bytes, queueMS, syscallMS, max(0, workerMS - syscallMS),
                        queuedAt.map { _ in ContinuousClock.now })
            }
        }
        if let finishedAt {
            diagnostics?.posixRead(queueMS: queueMS, syscallMS: syscallMS, workerOtherMS: workerOtherMS,
                                   resumeMS: PTPTransferDiagnostics.milliseconds(since: finishedAt))
        }
        return bytes
    }

    func send(_ bytes: Data) async throws {
        try await onQueue(writeQueue) { fd in
            try Self.sendBlocking(bytes, descriptor: fd)
        }
    }

    /// Android's downloadToFile/readPacketRaw loop stays on one IO worker.
    /// Only the byte execution model changes; the caller still owns PTP state.
    func withPacketPump<T: Sendable>(
        buffered: Data,
        activity: @escaping @Sendable () -> Void,
        diagnostics: PTPTransferDiagnostics?,
        readTimeoutNanoseconds: UInt64,
        preserveBuffered: @escaping @Sendable (Data) -> Void,
        operation: @escaping @Sendable (PTPIPBorrowedPacketRead, (Data) throws -> Void) throws -> T
    ) async throws -> T {
        try await onQueue(readQueue) { [self] fd in
            // Android Socket.soTimeout bounds each underlying read, not the
            // whole packet or the writer's synchronous work between reads.
            let previousTimeout = try Self.installReceiveTimeout(fd, nanoseconds: readTimeoutNanoseconds)
            defer { Self.restoreReceiveTimeout(fd, previousTimeout) }
            diagnostics?.continuousReadWorkerStarted()
            let reader = packetReader ?? PTPIPPOSIXPacketReader()
            packetReader = reader
            reader.seed(buffered)
            defer { preserveBuffered(reader.takeRemaining()) }
            return try operation({ consume in
                try reader.withPacket(receive: { buffer in
                    let started = diagnostics.map { _ in ContinuousClock.now }
                    var count: Int
                    while true {
                        count = Darwin.recv(fd, buffer.baseAddress, buffer.count, 0)
                        let savedError = count < 0 ? errno : 0
                        if count < 0, savedError == EINTR { continue }
                        if count < 0 {
                            if savedError == EAGAIN || savedError == EWOULDBLOCK { throw PTPSessionError.timeout }
                            throw ChannelError.system(savedError)
                        }
                        guard count > 0 else { throw ChannelError.closed }
                        break
                    }
                    let elapsed = started.map { PTPTransferDiagnostics.milliseconds(since: $0) } ?? 0
                    // Notify on every short read, not only on a full packet.
                    activity()
                    diagnostics?.posixRead(queueMS: 0, syscallMS: elapsed, workerOtherMS: 0, resumeMS: 0)
                    diagnostics?.read(bytes: count, waitedMS: elapsed)
                    return count
                }, consume: consume)
            }, { bytes in
                // Serialize PONG with all other sends on this connection.
                // The pump's active-operation lease keeps fd alive throughout.
                try self.writeQueue.sync { try Self.sendBlocking(bytes, descriptor: fd) }
            })
        }
    }

    static func receiveTimeout(nanoseconds: UInt64) -> timeval {
        // Zero timeval means no timeout. Round a positive sub-microsecond
        // budget up instead of accidentally allowing an infinite read.
        let micros = max(1, nanoseconds / 1000 + (nanoseconds % 1000 == 0 ? 0 : 1))
        return timeval(tv_sec: Int(micros / 1_000_000), tv_usec: Int32(micros % 1_000_000))
    }

    private static func installReceiveTimeout(_ fd: Int32, nanoseconds: UInt64) throws -> timeval {
        var previous = timeval()
        var length = socklen_t(MemoryLayout<timeval>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &previous, &length) == 0 else { throw ChannelError.system(errno) }
        var timeout = receiveTimeout(nanoseconds: nanoseconds)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, length) == 0 else { throw ChannelError.system(errno) }
        return previous
    }

    private static func restoreReceiveTimeout(_ fd: Int32, _ previous: timeval) {
        var value = previous
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func sendBlocking(_ bytes: Data, descriptor fd: Int32) throws {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw ChannelError.system(errno)
                }
                guard written > 0 else { throw ChannelError.closed }
                offset += written
            }
        }
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            // Wake blocked recv/send, but defer close until all active syscalls
            // finish. Otherwise descriptor reuse could target another socket.
            Darwin.shutdown(descriptor, SHUT_RDWR)
            closeDescriptorIfUnused()
        }
    }

    private var isClosed: Bool { lock.withLock { closed } }
    private func closeDescriptorIfUnused() {
        if closed, activeOperations == 0, descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    private func onQueue<T: Sendable>(_ queue: DispatchQueue,
                                     _ operation: @escaping @Sendable (Int32) throws -> T) async throws -> T {
        // Accepted sockets are session-owned: cancelling one waiter does not
        // close or abandon a read. PTP recovery must decide when to drain/close.
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let fd = try lock.withLock {
                        guard !closed else { throw ChannelError.closed }
                        activeOperations += 1
                        return descriptor
                    }
                    defer {
                        lock.withLock {
                            activeOperations -= 1
                            closeDescriptorIfUnused()
                        }
                    }
                    continuation.resume(returning: try operation(fd))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func setOption(_ fd: Int32, level: Int32, name: Int32, value: Int32) throws {
        var option = value
        guard setsockopt(fd, level, name, &option, socklen_t(MemoryLayout.size(ofValue: option))) == 0 else {
            throw ChannelError.system(errno)
        }
    }
    private static func address(_ host: String, port: UInt16) throws -> sockaddr_in {
        var result = sockaddr_in()
        result.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        result.sin_family = sa_family_t(AF_INET)
        result.sin_port = port.bigEndian
        guard host.withCString({ inet_pton(AF_INET, $0, &result.sin_addr) }) == 1 else { throw ChannelError.invalidAddress }
        return result
    }
    private static func withSockaddr<T>(_ address: sockaddr_in, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var address = address
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }
}

/// Queue-confined equivalent of BufferedInputStream + PacketReader.readPacketRaw.
/// Returned packets remain ordinary owning Data, never borrowed raw pointers.
final class PTPIPPOSIXPacketReader {
    private var input = [UInt8](repeating: 0, count: 64 * 1024)
    private var inputOffset = 0
    private var inputCount = 0
    private var initial = Data()
    private var initialOffset = 0
    private var header = Data(count: PTPIPCodec.headerSize)
    // Like Android ensureCapacity: small control packets never shrink storage.
    private var body = Data(count: 1024 * 1024)

    func seed(_ bytes: Data) {
        precondition(inputOffset == inputCount && initialOffset == initial.count)
        initial = bytes
        initialOffset = 0
    }

    func takeRemaining() -> Data {
        var remaining = Data(initial.dropFirst(initialOffset))
        if inputOffset < inputCount { remaining.append(contentsOf: input[inputOffset..<inputCount]) }
        initial = Data(); initialOffset = 0
        inputOffset = 0; inputCount = 0
        return remaining
    }

    func readPacket(receive: (UnsafeMutableRawBufferPointer) throws -> Int) throws -> PTPIPPacket {
        try withPacket(receive: receive) { type, bytes in
            PTPIPPacket(type: type, payload: Data(bytes))
        }
    }

    /// Android PacketReader.readPacketRaw: storage is valid only inside consume.
    /// No owning Data slice leaves this scope on the production download path.
    func withPacket<T>(receive: (UnsafeMutableRawBufferPointer) throws -> Int,
                       consume: (PTPIPPacketType, UnsafeRawBufferPointer) throws -> T) throws -> T {
        // Avoid overlapping access to self.header/body and the input cursors.
        // Swapping out the storage (rather than copying it) preserves COW reuse.
        var header = Data()
        swap(&header, &self.header)
        defer { swap(&header, &self.header) }
        try fill(&header, count: PTPIPCodec.headerSize, receive: receive)
        let length = header.withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).littleEndian) }
        guard length >= PTPIPCodec.headerSize, length <= PTPIPCodec.maxPacketLength else {
            throw PTPIPCodecError.malformedLength
        }
        var body = Data()
        swap(&body, &self.body)
        defer { swap(&body, &self.body) }
        let payloadLength = length - PTPIPCodec.headerSize
        if body.count < payloadLength { body.count = payloadLength }
        try fill(&body, count: payloadLength, receive: receive)
        let rawType = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian }
        guard let type = PTPIPPacketType(rawValue: rawType) else { throw PTPIPCodecError.unsupportedPacketType(rawType) }
        return try body.withUnsafeBytes { bytes in
            try consume(type, UnsafeRawBufferPointer(rebasing: bytes[..<payloadLength]))
        }
    }

    private func fill(_ destination: inout Data, count: Int,
                      receive: (UnsafeMutableRawBufferPointer) throws -> Int) throws {
        guard count > 0 else { return }
        try destination.withUnsafeMutableBytes { storage in
            let target = UnsafeMutableRawBufferPointer(rebasing: storage[..<count])
            var written = 0
            while written < target.count {
                if initialOffset < initial.count {
                    let count = min(target.count - written, initial.count - initialOffset)
                    initial.withUnsafeBytes { source in
                        target.baseAddress!.advanced(by: written).copyMemory(
                            from: source.baseAddress!.advanced(by: initialOffset), byteCount: count)
                    }
                    initialOffset += count; written += count
                    continue
                }
                if inputOffset == inputCount {
                    // BufferedInputStream.read1 bypasses its staging buffer
                    // for large unmarked reads. Read straight into packet
                    // storage here too; a short recv still renews activity.
                    if target.count - written >= input.count {
                        let direct = UnsafeMutableRawBufferPointer(rebasing: target[written...])
                        let count = try receive(direct)
                        guard count > 0, count <= direct.count else {
                            throw PTPIPPOSIXChannel.ChannelError.closed
                        }
                        written += count
                        continue
                    }
                    inputCount = try input.withUnsafeMutableBytes(receive)
                    guard inputCount > 0, inputCount <= input.count else {
                        throw PTPIPPOSIXChannel.ChannelError.closed
                    }
                    inputOffset = 0
                }
                let count = min(target.count - written, inputCount - inputOffset)
                input.withUnsafeBytes { source in
                    target.baseAddress!.advanced(by: written).copyMemory(
                        from: source.baseAddress!.advanced(by: inputOffset), byteCount: count)
                }
                inputOffset += count; written += count
            }
        }
    }
}
