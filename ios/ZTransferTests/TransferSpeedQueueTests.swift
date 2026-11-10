import XCTest
import Combine
@testable import ZTransfer

@MainActor
final class TransferSpeedQueueTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: Int64 = 0
        func now() -> Int64 { lock.withLock { time } }
        func set(_ value: Int64) { lock.withLock { time = value } }
    }
    private actor Camera: TransferDownloading {
        var samples: [UInt32: @Sendable (TransferDownloadProgress) -> Void] = [:]
        var waiting: [UInt32: CheckedContinuation<Void, Never>] = [:]
        func download(file: CameraFile, to directory: URL, progress: (@Sendable (Double) -> Void)?) async throws -> URL {
            throw CameraTransportError.unavailable
        }
        func downloadWithMetrics(file: CameraFile, to directory: URL,
                                 progress: (@Sendable (TransferDownloadProgress) -> Void)?) async throws -> URL {
            samples[file.id] = progress
            await withCheckedContinuation { waiting[file.id] = $0 }
            let url = directory.appendingPathComponent(file.fileName)
            try Data(repeating: 1, count: Int(file.size)).write(to: url)
            return url
        }
        func emit(_ id: UInt32, bytes: UInt64, speed: Int64) {
            samples[id]?(.init(fraction: Double(bytes) / 1000, downloaded: bytes, total: 1000, bytesPerSecond: speed))
        }
        func ready(_ id: UInt32) -> Bool { waiting[id] != nil }
        func finish(_ id: UInt32) { waiting.removeValue(forKey: id)?.resume() }
    }
    func testProductionQueueSamplesSpeedButPublishesEveryByteAndResetsForNextFile() async throws {
        let suite = "TransferSpeedQueue.\(UUID())"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory); UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let clock = Clock(), camera = Camera()
        let queue = TransferQueue(defaults: UserDefaults(suiteName: suite)!, premiumAccess: PremiumAccess(.lifetime), transferSpeedNow: { clock.now() })
        let model = TransferQueueViewModel(queue: queue)
        var structuralPublications = 0
        let observation = model.$snapshot.sink { _ in structuralPublications += 1 }
        defer { observation.cancel() }
        let files = (1...2).map { CameraFile(id: UInt32($0), storageID: 1, format: 0x3801,
            size: 1000, fileName: "\($0).JPG", captureDate: nil, isProtected: false) }
        let ids = await queue.enqueue(files)
        await queue.start(session: camera, directory: directory)
        func wait(_ check: () async -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !(await check()) {
                if ContinuousClock.now >= deadline { XCTFail("Timed out"); throw CocoaError(.coderInvalidValue) }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        try await wait { await camera.ready(1) && model.activeProgress?.taskID == ids[0] }
        let before = structuralPublications
        for (time, bytes, speed, expected) in [(0, 1, 0, 0), (100, 2, 5000, 5000),
            (699, 300, 9000, 5000), (700, 400, 10000, 10000), (1300, 500, 0, 10000), (1301, 600, 11000, 11000),
            (1350, 700, 12000, 11000)] {
            clock.set(Int64(time)); await camera.emit(1, bytes: UInt64(bytes), speed: Int64(speed))
            try await wait { model.activeProgress?.downloadedBytes == UInt64(bytes) }
            XCTAssertEqual(model.activeProgress?.bytesPerSecond, Int64(expected))
            XCTAssertEqual(model.activeProgress?.retainedBytesPerSecond, Int64(expected))
            XCTAssertEqual(model.activeProgress?.fraction ?? -1, Double(bytes) / 1000, accuracy: 0.0001)
        }
        XCTAssertEqual(structuralPublications, before, "Raw progress cannot invalidate list snapshots")
        await camera.finish(1)
        try await wait { await camera.ready(2) && model.activeProgress?.taskID == ids[1] }
        XCTAssertEqual(model.activeProgress?.bytesPerSecond, 0)
        XCTAssertEqual(model.activeProgress?.retainedBytesPerSecond, 12000, "Next preparation uses latest raw positive speed")
        clock.set(1360); await camera.emit(2, bytes: 1, speed: 0)
        try await wait { model.activeProgress?.downloadedBytes == 1 }
        XCTAssertEqual(model.activeProgress?.retainedBytesPerSecond, 12000)
        clock.set(1370); await camera.emit(2, bytes: 2, speed: 15000)
        try await wait { model.activeProgress?.downloadedBytes == 2 }
        XCTAssertEqual(model.activeProgress?.bytesPerSecond, 15000, "Next file has no 600ms delay on its first real sample")
        await camera.emit(1, bytes: 999, speed: 99999)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.activeProgress?.taskID, ids[1]); XCTAssertEqual(model.activeProgress?.bytesPerSecond, 15000)
        await camera.finish(2)
        try await wait { !model.snapshot.isTransferring && model.snapshot.items.allSatisfy { $0.status == .completed } }
        XCTAssertNil(model.activeProgress)
    }
}
