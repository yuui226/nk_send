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
    func testSTAPairingTimeoutLeavesNoReaderToStealFollowingEvents() async throws {
        let peer = try PTPIPRecoveryPeer(behavior: .smallTransfer)
        let transport = try await peer.connect(backend: .bsdSocket)
        let consumer = SuspendedEventConsumer()
        defer { transport.close(); peer.close(); Task { await consumer.release() } }
        await transport.waitForPairingEvent(timeoutNanoseconds: 100_000_000)
        await consumer.release()
        transport.startEvents { await consumer.receive($0) }
        try await peer.sendEvents([42], ping: true)
        try await waitUntil { peer.pongCount == 1 }
        try await waitUntilAsync { await consumer.values.count == 1 }
        let events = await consumer.values
        XCTAssertEqual(events.map(\.handle), [42])
    }

    func testSTAPairingFragmentedPacketUsesPerReadRemainingBudgetLikeAndroid() async throws {
        let peer = try PTPIPRecoveryPeer(behavior: .smallTransfer)
        let transport = try await peer.connect(backend: .bsdSocket)
        defer { transport.close(); peer.close() }
        let started = ContinuousClock.now
        let waiting = Task {
            await transport.waitForPairingEvent(timeoutNanoseconds: 250_000_000)
            return started.duration(to: .now)
        }
        defer { waiting.cancel() }
        try await peer.sendFragmentedPairingEvent()
        let waitDuration = await waiting.value
        XCTAssertGreaterThan(waitDuration, .milliseconds(400))
        // The whole fragmented packet was consumed, not abandoned after 250 ms.
        transport.startEvents()
        try await peer.sendEvents([], ping: true)
        try await waitUntil { peer.pongCount == 1 }
    }

    func testSTAEventQueueIsBoundedFIFOAndSlowConsumerDoesNotBlockPong() async throws {
        let peer = try PTPIPRecoveryPeer(behavior: .smallTransfer)
        let transport = try await peer.connect(backend: .bsdSocket)
        let consumer = SuspendedEventConsumer()
        defer { transport.close(); peer.close(); Task { await consumer.release() } }
        transport.startEvents { await consumer.receive($0) }
        transport.startEvents { _ in XCTFail("Duplicate reader/delivery must not start") }
        try await peer.sendEvents([1])
        try await waitUntilAsync { await consumer.values.count == 1 }
        // First consumer is suspended, so exactly 64 subsequent events fit.
        try await peer.sendEvents(Array(2...75), malformedFirst: true, ping: true)
        try await waitUntil { peer.pongCount == 1 }
        let blocked = await consumer.values
        XCTAssertEqual(blocked.map(\.handle), [1])
        await consumer.release()
        try await waitUntilAsync { await consumer.values.count == 65 }
        let delivered = await consumer.values
        XCTAssertEqual(delivered.map(\.handle), Array(1...65))
        XCTAssertTrue(delivered.allSatisfy { $0.code == 0x4002 })
        let session = PTPSession(transport: transport)
        let response = try await session.execute(operation: PTPConstants.getDeviceInfo)
        XCTAssertEqual(response.code, PTPConstants.responseOK)
        XCTAssertTrue(peer.cancelledTransactions.isEmpty)
    }

    func testClosingSTAEventDeliveryDropsQueuedEventsWithoutStartingAnotherConsumer() async throws {
        let peer = try PTPIPRecoveryPeer(behavior: .smallTransfer)
        let transport = try await peer.connect(backend: .bsdSocket)
        let consumer = SuspendedEventConsumer()
        defer { transport.close(); peer.close(); Task { await consumer.release() } }
        transport.startEvents { await consumer.receive($0) }
        try await peer.sendEvents([1])
        try await waitUntilAsync { await consumer.values.count == 1 }
        try await peer.sendEvents([2, 3], ping: true)
        try await waitUntil { peer.pongCount == 1 }
        transport.close()
        transport.startEvents { _ in XCTFail("Closed transport must not restart delivery") }
        await consumer.release()
        try await waitUntilAsync { await consumer.completed == 1 }
        let delivered = await consumer.values
        XCTAssertEqual(delivered.map(\.handle), [1])
    }

    func testEventReaderWithoutSubscriberStillRespondsToPing() async throws {
        let peer = try PTPIPRecoveryPeer(behavior: .smallTransfer)
        let transport = try await peer.connect(backend: .bsdSocket)
        defer { transport.close(); peer.close() }
        transport.startEvents()
        try await peer.sendEvents([1], ping: true)
        try await waitUntil { peer.pongCount == 1 }
    }

    private func waitUntilAsync(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw PTPSessionError.timeout }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func testTCPParametersPreserveDefaultACKPolicyNoDelayAndRouting() throws {
        let sta = PTPIPSocketTransport.parameters(localAddress: "192.168.1.2", sta: true)
        let ap = PTPIPSocketTransport.parameters(sta: false)
        let staTCP = try XCTUnwrap(sta.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)
        let apTCP = try XCTUnwrap(ap.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)
        XCTAssertEqual(staTCP.disableAckStretching, NWProtocolTCP.Options().disableAckStretching)
        XCTAssertEqual(apTCP.disableAckStretching, NWProtocolTCP.Options().disableAckStretching)
        XCTAssertTrue(staTCP.noDelay)
        XCTAssertTrue(apTCP.noDelay)
        XCTAssertEqual(sta.prohibitedInterfaceTypes, [.cellular, .loopback])
        XCTAssertEqual(sta.requiredLocalEndpoint, .hostPort(host: "192.168.1.2", port: .any))
        XCTAssertEqual(ap.requiredInterfaceType, .wifi)
        XCTAssertEqual(ap.prohibitedInterfaceTypes, [.loopback])
    }

    func testBulkDownloadMatchesBufferedBytesAndReportsTransportTimings() async throws {
        try await checkBulkDownload(backend: .networkFramework)
    }

    func testBSDBulkDownloadUsesSameFramingAndPreservesBytes() async throws {
        try await checkBulkDownload(backend: .bsdSocket)
    }

    func testBSDBorrowedBulkDownloadPreservesBytesWithoutOwningCallbacks() async throws {
        try await checkBulkDownload(backend: .bsdSocket, borrowed: true)
    }

    func testBSDUnknownLengthDownloadConsumesResponseAndKeepsSessionUsable() async throws {
        let peer = try PTPIPRecoveryPeer(behavior: .unknownLengthTransfer)
        let transport = try await peer.connect(backend: .bsdSocket)
        defer { transport.close(); peer.close() }
        let session = PTPSession(transport: transport)
        let received = ReceivedBytes()
        let sink = PTPDataSink(started: { XCTAssertNil($0) }, received: { _ in
            XCTFail("STA download should consume the borrowed payload")
        }, receivedBorrowed: { try received.sink.received(Data($0)) })
        let result = try await session.executeReceiving(operation: PTPConstants.getObject,
                                                        parameters: [12], sink: sink)
        XCTAssertEqual(result.code, PTPConstants.responseOK)
        XCTAssertEqual(result.receivedByteCount, 3)
        XCTAssertNil(result.declaredByteCount)
        XCTAssertEqual(received.bytes, Data([1, 2, 3]))
        let next = try await session.execute(operation: PTPConstants.getDeviceInfo)
        XCTAssertEqual(next.code, PTPConstants.responseOK)
        XCTAssertEqual(next.transactionID, result.transactionID + 1)
        XCTAssertTrue(peer.cancelledTransactions.isEmpty)
        let invalidated = await session.isInvalidated
        XCTAssertFalse(invalidated)
    }

    func testBSDCancellationDrainsBeforeReusingSession() async throws {
        try await checkCancellation(behavior: .cancel, backend: .bsdSocket)
    }

    func testBSDDrainRenewsInactivityDeadline() async throws {
        try await checkCancellation(behavior: .slowDrain, backend: .bsdSocket)
    }

    private func checkBulkDownload(backend: PTPIPSocketBackend, borrowed: Bool = false) async throws {
        let peer = try PTPIPRecoveryPeer(behavior: .bulkTransfer)
        let transport = try await peer.connect(backend: backend)
        defer { transport.close(); peer.close() }
        let session = PTPSession(transport: transport)
        let bufferedStart = ContinuousClock.now
        let buffered = try await session.execute(operation: PTPConstants.getObject, parameters: [12])
        let bufferedTime = bufferedStart.duration(to: .now)
        XCTAssertEqual(buffered.data.count, 16 * 1024 * 1024)
        let received = ReceivedBytes()
        let records = DiagnosticRecords()
        let diagnostics = PTPTransferDiagnostics(emit: { records.append($0) })
        diagnostics.beginFile(size: UInt64(buffered.data.count))
        diagnostics.beginChunk(offset: 0, requested: UInt64(buffered.data.count))
        diagnostics.gateAcquired()
        var sink = received.sink
        if borrowed {
            sink = PTPDataSink(started: received.sink.started, received: { _ in
                XCTFail("BSD download must use the synchronous borrowed callback")
            }, receivedBorrowed: { bytes in try received.sink.received(Data(bytes)) })
        }
        sink.diagnostics = diagnostics
        let streamingStart = ContinuousClock.now
        let streamed = try await session.executeReceiving(operation: PTPConstants.getObject,
                                                           parameters: [12], sink: sink)
        diagnostics.endChunk(code: PTPConstants.responseOK)
        diagnostics.finish(success: true, finalizeMS: 0)
        let streamingTime = streamingStart.duration(to: .now)
        XCTAssertEqual(streamed.receivedByteCount, UInt64(buffered.data.count))
        XCTAssertEqual(received.bytes, buffered.data)
        let summary = try XCTUnwrap(records.values.last)
        XCTAssertEqual(summary["event"], "file_end")
        XCTAssertEqual(Double(summary["payload_bytes"] ?? ""), Double(buffered.data.count))
        XCTAssertGreaterThan(Double(summary["wire_bytes"] ?? "") ?? 0, Double(buffered.data.count))
        XCTAssertGreaterThan(Double(summary["read_calls"] ?? "") ?? 0, 0)
        XCTAssertNotNil(summary["session_acquired_ms"])
        XCTAssertNotNil(summary["command_sent_ms"])
        XCTAssertNotNil(summary["first_read_ms"])
        XCTAssertEqual(summary["bsd_socket"], backend == .bsdSocket ? "1.000" : "0.000")
        if backend == .bsdSocket {
            XCTAssertEqual(summary["posix_phase_worker_calls"], "1.000")
            XCTAssertGreaterThanOrEqual(Double(summary["kernel_receive_buffer_bytes"] ?? "") ?? 0, 4 * 1024 * 1024)
            XCTAssertEqual(summary["tcp_info_available"], "1.000")
            XCTAssertEqual(summary["tcp_send_more_acks"], "1.000")
            let chunkRX = try XCTUnwrap(Double(summary["tcp_rx_bytes_chunk"] ?? ""))
            let totalRX = try XCTUnwrap(Double(summary["tcp_rx_bytes_total"] ?? ""))
            XCTAssertGreaterThanOrEqual(chunkRX, Double(buffered.data.count))
            XCTAssertGreaterThan(totalRX, chunkRX) // Earlier buffered download is excluded.
            XCTAssertNotNil(summary["tcp_receive_window_scale"])
            XCTAssertNotNil(summary["tcp_rx_out_of_order_bytes_chunk"])
            XCTAssertEqual(summary["posix_read_calls"], summary["read_calls"])
            let phases = try ["posix_queue_wait_ms", "posix_syscall_ms", "posix_worker_other_ms", "posix_resume_wait_ms"].map {
                try XCTUnwrap(Double(summary[$0] ?? ""))
            }
            XCTAssertTrue(phases.allSatisfy { $0 >= 0 })
            XCTAssertLessThanOrEqual(phases.reduce(0, +), try XCTUnwrap(Double(summary["receive_wait_ms"] ?? "")) + 0.01)
        } else {
            XCTAssertNil(summary["posix_phase_worker_calls"])
            XCTAssertEqual(summary["kernel_receive_buffer_bytes"], "-1.000")
            XCTAssertEqual(summary["tcp_info_available"], "0.000")
            XCTAssertNil(summary["tcp_rx_bytes_chunk"])
        }
        print("PTP/IP \(backend) loopback 16 MiB, 16 KiB frames: buffered=\(bufferedTime), streaming=\(streamingTime)")
        // No timing assertion: this measures host callback overhead, not the
        // phone/camera Wi-Fi link, and cannot certify real-device throughput.
        let next = try await session.execute(operation: PTPConstants.getDeviceInfo)
        XCTAssertEqual(next.transactionID, 3)
        let secondReceived = ReceivedBytes()
        let second = try await session.executeReceiving(operation: PTPConstants.getObject,
                                                        parameters: [12], sink: secondReceived.sink)
        XCTAssertEqual(second.receivedByteCount, streamed.receivedByteCount)
        XCTAssertEqual(secondReceived.bytes, buffered.data)
        XCTAssertTrue(peer.cancelledTransactions.isEmpty)
    }
    func testDiagnosticsResetChunkCountersButRetainFileWriteTotals() throws {
        let records = DiagnosticRecords()
        let diagnostics = PTPTransferDiagnostics(emit: { records.append($0) })
        diagnostics.beginFile(size: 300)
        diagnostics.beginChunk(offset: 0, requested: 100)
        diagnostics.transport(bsdSocket: true, receiveBufferBytes: 4194304,
                              tcpSnapshot: { ["tcp_rx_bytes_total": 1000] })
        diagnostics.read(bytes: 112, waitedMS: 75)
        diagnostics.posixRead(queueMS: 1, syscallMS: 60, workerOtherMS: 2, resumeMS: 3)
        diagnostics.sink(bytes: 100, elapsedMS: 2)
        diagnostics.write(bytes: 100, elapsedMS: 1)
        diagnostics.endChunk(code: PTPConstants.responseOK)
        diagnostics.beginChunk(offset: 100, requested: 200)
        diagnostics.read(bytes: 212, waitedMS: 5)
        diagnostics.sink(bytes: 200, elapsedMS: 3)
        diagnostics.write(bytes: 200, elapsedMS: 2)
        diagnostics.endChunk(code: nil)
        diagnostics.finish(success: false, finalizeMS: 4)
        let second = try XCTUnwrap(records.values.last)
        XCTAssertEqual(second["chunk"], "2.000")
        XCTAssertNil(second["tcp_rx_bytes_total"])
        XCTAssertNil(second["tcp_rx_bytes_chunk"])
        XCTAssertNil(second["posix_read_calls"])
        XCTAssertNil(second["posix_syscall_ms"])
        XCTAssertEqual(second["wire_bytes"], "212.000")
        XCTAssertEqual(second["payload_bytes"], "200.000")
        XCTAssertEqual(second["receive_wait_ms"], "5.000")
        XCTAssertNil(second["reads_waiting_50ms"])
        XCTAssertEqual(second["file_write_calls"], "2.000")
        XCTAssertEqual(second["file_write_ms"], "3.000")
        XCTAssertEqual(second["success"], "0.000")
        XCTAssertEqual(second["finalize_ms"], "4.000")
        XCTAssertNotNil(second["between_chunks_ms"])
        XCTAssertEqual(records.values.filter { $0["event"] == "chunk_end" }.last?["response_code"], "-1.000")
    }
    func testDownloadTimeoutRenewsDuringAPartiallyReceivedDataPacket() async throws {
        try await checkSlowTransfer(backend: .networkFramework)
    }

    func testBSDDownloadTimeoutRenewsDuringPartiallyReceivedPacket() async throws {
        try await checkSlowTransfer(backend: .bsdSocket)
    }

    func testBSDReadTimeoutDoesNotIncludeSynchronousWriterTime() async throws {
        let peer = try PTPIPRecoveryPeer(behavior: .smallTransfer)
        let transport = try await peer.connect(backend: .bsdSocket)
        defer { transport.close(); peer.close() }
        let session = PTPSession(transport: transport)
        let received = ReceivedBytes()
        let sink = PTPDataSink(started: received.sink.started,
                               received: { _ in XCTFail("Expected borrowed download") },
                               receivedBorrowed: { bytes in
            // Synchronous like a slow File Provider, not a network stall.
            Thread.sleep(forTimeInterval: 0.6)
            try received.sink.received(Data(bytes))
        })
        let result = try await session.executeReceiving(operation: PTPConstants.getObject, parameters: [12],
                                                        sink: sink, timeoutNanoseconds: 250_000_000)
        XCTAssertEqual(result.code, PTPConstants.responseOK)
        XCTAssertEqual(received.bytes, Data([1, 2, 3]))
        XCTAssertTrue(peer.cancelledTransactions.isEmpty)
        let next = try await session.execute(operation: PTPConstants.getDeviceInfo)
        XCTAssertEqual(next.transactionID, 2)
    }

    func testBSDOrdinaryCommandTimeoutRenewsForEachShortRead() async throws {
        let peer = try PTPIPRecoveryPeer(behavior: .slowTransfer)
        let transport = try await peer.connect(backend: .bsdSocket)
        defer { transport.close(); peer.close() }
        let session = PTPSession(transport: transport)
        let reply = try await session.executeResponse(operation: PTPConstants.getObject, parameters: [12],
                                                       timeoutNanoseconds: 250_000_000)
        XCTAssertEqual(reply.data, Data(1...8))
        XCTAssertTrue(peer.cancelledTransactions.isEmpty)
    }

    func testBSDSocketReadTimeoutDrainsBeforeReusingSession() async throws {
        let peer = try PTPIPRecoveryPeer(behavior: .cancel)
        let transport = try await peer.connect(backend: .bsdSocket)
        defer { transport.close(); peer.close() }
        let session = PTPSession(transport: transport)
        do {
            _ = try await session.executeReceivingBuffered(operation: PTPConstants.getObjectSize, parameters: [12],
                                                            timeoutNanoseconds: 100_000_000)
            XCTFail("Expected kernel read timeout")
        } catch { XCTAssertEqual(error as? PTPSessionError, .timeout) }
        let next = try await session.execute(operation: PTPConstants.getDeviceInfo)
        XCTAssertEqual(next.transactionID, 2)
        XCTAssertEqual(peer.cancelledTransactions, [1])
    }

    private func checkSlowTransfer(backend: PTPIPSocketBackend) async throws {
        let peer = try PTPIPRecoveryPeer(behavior: .slowTransfer)
        let transport = try await peer.connect(backend: backend)
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

    func testScrollingAwayFinishesBufferedThumbnailWithoutSendingPTPCancel() async throws {
        try await checkScrollingAway(backend: .networkFramework)
    }

    func testBSDScrollingAwayFinishesBufferedThumbnailWithoutSendingPTPCancel() async throws {
        try await checkScrollingAway(backend: .bsdSocket)
    }

    private func checkScrollingAway(backend: PTPIPSocketBackend) async throws {
        let peer = try PTPIPRecoveryPeer(behavior: .slowTransfer)
        let transport = try await peer.connect(backend: backend)
        defer { transport.close(); peer.close() }
        let session = PTPSession(transport: transport)
        let call = Task {
            try await session.execute(operation: PTPConstants.getObject, parameters: [12])
        }
        try await waitUntil { peer.startedTransactions > 0 }
        let queued = Task { try await session.execute(operation: PTPConstants.getDeviceInfo) }
        call.cancel()
        do { _ = try await call.value; XCTFail("Cancelled thumbnail succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        let next = try await queued.value
        XCTAssertEqual(next.transactionID, 2)
        XCTAssertTrue(peer.cancelledTransactions.isEmpty)
        XCTAssertEqual(peer.pongCount, 0)
    }

    func testDrainMayLastLongerThanThreeSecondsWhileDataKeepsArriving() async throws {
        try await checkCancellation(behavior: .slowDrain)
    }

    private func checkCancellation(behavior: PTPIPRecoveryPeer.Behavior, backend: PTPIPSocketBackend = .networkFramework) async throws {
        let peer = try PTPIPRecoveryPeer(behavior: behavior)
        let transport = try await peer.connect(backend: backend)
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
        try await checkWriteFailure(backend: .networkFramework)
    }

    func testBSDWriteFailureDrainsAndPreservesSession() async throws {
        try await checkWriteFailure(backend: .bsdSocket)
    }

    func testBSDBorrowedWriteFailureDrainsAndPreservesSession() async throws {
        try await checkWriteFailure(backend: .bsdSocket, borrowed: true)
    }

    private func checkWriteFailure(backend: PTPIPSocketBackend, borrowed: Bool = false) async throws {
        let peer = try PTPIPRecoveryPeer(behavior: .writeFailure)
        let transport = try await peer.connect(backend: backend)
        defer { transport.close(); peer.close() }
        let session = PTPSession(transport: transport)
        var sink = PTPDataSink(started: { _ in }, received: { _ in throw WriteFailure.diskFull })
        if borrowed {
            sink = PTPDataSink(started: { _ in }, received: { _ in XCTFail("Unexpected owning callback") },
                               receivedBorrowed: { _ in throw WriteFailure.diskFull })
        }
        do {
            _ = try await session.executeReceiving(operation: PTPConstants.getObject, parameters: [12], sink: sink)
            XCTFail("Write failure was lost")
        } catch { XCTAssertEqual(error as? WriteFailure, .diskFull) }
        let next = try await session.execute(operation: PTPConstants.getDeviceInfo)
        XCTAssertEqual(next.transactionID, 2)
        XCTAssertEqual(peer.cancelledTransactions, [1])
    }

    func testSilentCameraAfterCancelTimesOutAndRetiresSession() async throws {
        try await checkSilentCamera(backend: .networkFramework)
    }

    func testBSDSilentCameraRetiresAndUnblocksPendingRead() async throws {
        try await checkSilentCamera(backend: .bsdSocket)
    }

    private func checkSilentCamera(backend: PTPIPSocketBackend) async throws {
        let peer = try PTPIPRecoveryPeer(behavior: .silent)
        let transport = try await peer.connect(backend: backend)
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

private actor SuspendedEventConsumer {
    private(set) var values: [STAEvent] = []
    private(set) var completed = 0
    private var blocked = true
    private var continuation: CheckedContinuation<Void, Never>?
    func receive(_ event: STAEvent) async {
        values.append(event)
        if blocked { await withCheckedContinuation { continuation = $0 } }
        completed += 1
    }
    func release() {
        blocked = false
        continuation?.resume()
        continuation = nil
    }
}

private final class DiagnosticRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[String: String]] = []
    var values: [[String: String]] { lock.withLock { storage } }
    func append(_ line: String) {
        guard let data = line.data(using: .utf8),
              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { return }
        lock.withLock { storage.append(record) }
    }
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
    enum Behavior: Sendable { case cancel, writeFailure, slowDrain, silent, slowTransfer, bulkTransfer, smallTransfer, unknownLengthTransfer }
    private let behavior: Behavior
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ztransfer.tests.ptpip.recovery")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var eventConnection: NWConnection?
    private var tasks: [Task<Void, Never>] = []
    private var cancels: [UInt32] = []
    private var pongs = 0
    private var starts = 0
    var startedTransactions: Int { lock.withLock { starts } }
    var cancelledTransactions: [UInt32] { lock.withLock { cancels } }
    var pongCount: Int { lock.withLock { pongs } }

    func sendFragmentedPairingEvent() async throws {
        let connection = try lock.withLock { try XCTUnwrap(eventConnection) }
        let frame = try PTPIPCodec.encode(type: .event,
            payload: littleEndian(UInt16(0x4008)) + littleEndian(UInt32(0)) + littleEndian(UInt32(0)))
        try await sendBytes(Data(frame.prefix(8)), on: connection)
        for range in [8..<11, 11..<14, 14..<18] {
            try await Task.sleep(nanoseconds: 150_000_000)
            try await sendBytes(frame.subdata(in: range), on: connection)
        }
    }

    func sendEvents(_ handles: [UInt32], malformedFirst: Bool = false, ping: Bool = false) async throws {
        let connection = try lock.withLock { try XCTUnwrap(eventConnection) }
        var batch = Data()
        if malformedFirst { batch.append(try PTPIPCodec.encode(type: .event, payload: Data(repeating: 0, count: 5))) }
        for handle in handles {
            let payload = littleEndian(UInt16(0x4002)) + littleEndian(UInt32(0)) + littleEndian(handle)
            batch.append(try PTPIPCodec.encode(type: .event, payload: payload))
        }
        if ping { batch.append(try PTPIPCodec.encode(type: .ping)) }
        try await sendBytes(batch, on: connection)
    }

    init(behavior: Behavior) throws {
        self.behavior = behavior
        listener = try NWListener(using: .tcp, on: .any)
    }

    func connect(backend: PTPIPSocketBackend = .networkFramework) async throws -> PTPIPSocketTransport {
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
                                                  connectionParameters: .tcp, backend: backend)
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
                lock.withLock { eventConnection = connection }
                try await send(.initEventAck, on: connection)
            case .pong:
                lock.withLock { pongs += 1 }
            case .commandRequest:
                let operation = UInt16(packet.payload[4]) | UInt16(packet.payload[5]) << 8
                let transaction = uint32(packet.payload, at: 6)
                if operation == PTPConstants.getObject || operation == PTPConstants.getObjectSize {
                    lock.withLock { starts += 1 }
                    if behavior == .bulkTransfer {
                        try await send(.startData, payload: littleEndian(transaction) + littleEndian(UInt64(16 * 1024 * 1024)), on: connection)
                        let frame = try PTPIPCodec.encode(type: .data, payload: littleEndian(transaction) + Data(repeating: 0x5A, count: 16 * 1024))
                        var batch = Data()
                        for _ in 0..<16 { batch.append(frame) }
                        for _ in 0..<64 { try await sendBytes(batch, on: connection) }
                        try await send(.endData, payload: littleEndian(transaction), on: connection)
                        try await send(.commandResponse, payload: littleEndian(PTPConstants.responseOK) + littleEndian(transaction), on: connection)
                        continue
                    }
                    let declared = behavior == .unknownLengthTransfer ? UInt64.max : UInt64(behavior == .smallTransfer ? 3 : 256)
                    try await send(.startData, payload: littleEndian(transaction) + littleEndian(declared), on: connection)
                    if behavior == .writeFailure || behavior == .smallTransfer || behavior == .unknownLengthTransfer {
                        try await send(.data, payload: littleEndian(transaction) + Data([1, 2, 3]), on: connection)
                        if behavior == .unknownLengthTransfer {
                            try await send(.endData, payload: littleEndian(transaction), on: connection)
                        }
                        if behavior == .smallTransfer || behavior == .unknownLengthTransfer {
                            try await send(.commandResponse, payload: littleEndian(PTPConstants.responseOK) + littleEndian(transaction), on: connection)
                        }
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
