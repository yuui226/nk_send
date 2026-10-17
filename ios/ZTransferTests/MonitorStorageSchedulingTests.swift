import XCTest
@testable import ZTransfer

private actor MonitorStoragePermission {
    var allowed = true
    func revoke() { allowed = false }
}

/// Real repository/session wire path, including two complete download slices.
private actor MonitorStorageWire: PTPCommandTransport {
    let firstSlice = GateTestLatch(), releaseFirst = GateTestLatch()
    let lastSlice = GateTestLatch(), releaseLast = GateTestLatch()
    private(set) var operations: [UInt16] = []
    private var slices = 0

    func sendPTP(command: Data, data: Data?) async throws -> (response: Data, payload: Data) {
        let request = try PTPCodec.decode(command)
        operations.append(request.code)
        let payload: Data
        switch request.code {
        case PTPConstants.getPartialObjectEx:
            slices += 1
            if slices == 1 {
                await firstSlice.signal(); await releaseFirst.wait()
                payload = Data(repeating: 1, count: Int(transferChunkSize))
            } else {
                await lastSlice.signal(); await releaseLast.wait()
                payload = Data([2])
            }
        case PTPConstants.getStorageInfo:
            var bytes = Data(repeating: 0, count: 26)
            for (offset, value) in [(6, UInt64(3_000_000_000)), (14, UInt64(2_000_000_000))] {
                for i in 0..<8 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
            }
            payload = bytes
        default:
            throw PTPSessionError.responseCode(PTPConstants.operationNotSupported)
        }
        return (PTPCodec.encode(type: .response, code: PTPConstants.responseOK,
                               transactionID: request.transactionID), payload)
    }
}

final class MonitorStorageSchedulingTests: XCTestCase {
    func testStorageWaitsAcrossDownloadSlicesWhileHeartbeatSkips() async throws {
        try await verifyStorageRead(revokeWhileQueued: false)
    }

    func testPagePermissionIsRecheckedAfterDownloadBeforeSendingStorageCommand() async throws {
        try await verifyStorageRead(revokeWhileQueued: true)
    }

    private func verifyStorageRead(revokeWhileQueued: Bool) async throws {
        let wire = MonitorStorageWire()
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let camera = CameraSession(repository: repository)
        let permission = MonitorStoragePermission()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let download = Task {
            try await repository.downloadResult(handle: 7, size: transferChunkSize + 1,
                                                 fileName: "a.MP4", to: directory)
        }
        await wire.firstSlice.wait()
        let storage = Task { try await camera.monitorFreeBytes(storageID: 1) { await permission.allowed } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await repository.cameraSchedulerSnapshot().queued != 1, ContinuousClock.now < deadline { await Task.yield() }
        let queued = await repository.cameraSchedulerSnapshot()
        XCTAssertEqual(queued.queued, 1)
        XCTAssertEqual(queued.activeDownloads, 1)
        let heartbeat = await repository.keepalive()
        XCTAssertTrue(heartbeat)
        if revokeWhileQueued { await permission.revoke() }
        await wire.releaseFirst.signal()
        await wire.lastSlice.wait()
        let during = await wire.operations
        XCTAssertEqual(during, [PTPConstants.getPartialObjectEx, PTPConstants.getPartialObjectEx])
        await wire.releaseLast.signal()
        let result = try await download.value
        XCTAssertEqual(result.bytes, transferChunkSize + 1)
        let free = try await storage.value
        XCTAssertEqual(free, revokeWhileQueued ? nil : 2_000_000_000)
        let operations = await wire.operations
        XCTAssertEqual(operations.count, revokeWhileQueued ? 2 : 3)
        if !revokeWhileQueued { XCTAssertEqual(operations.last, PTPConstants.getStorageInfo) }
        let finished = await repository.cameraSchedulerSnapshot()
        XCTAssertEqual(finished.activeDownloads, 0)
        XCTAssertEqual(finished.queued, 0)
        XCTAssertNil(finished.activeKind)
    }
}
