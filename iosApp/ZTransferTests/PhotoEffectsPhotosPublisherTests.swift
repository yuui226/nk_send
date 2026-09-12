import XCTest
@testable import ZTransfer

private final class HeldEffectsPhotoLibrary: PhotoLibraryClient, @unchecked Sendable {
    private let lock = NSLock()
    private var authorized = false
    private var requests = 0
    private var submitted: [URL] = []
    private var pending: [(Bool, Error?) -> Void] = []
    private var peak = 0
    let onSubmit: @Sendable (Int) -> Void

    init(onSubmit: @escaping @Sendable (Int) -> Void) { self.onSubmit = onSubmit }

    func authorization() -> PhotoLibraryAuthorization {
        lock.lock(); defer { lock.unlock() }
        return authorized ? .allowed : .notDetermined
    }

    func requestAddOnly(_ completion: @escaping (PhotoLibraryAuthorization) -> Void) {
        lock.lock(); requests += 1; authorized = true; lock.unlock()
        completion(.allowed)
    }

    func importFile(_ url: URL, kind: PhotoImportKind, completion: @escaping (Bool, Error?) -> Void) {
        lock.lock()
        submitted.append(url); pending.append(completion)
        peak = max(peak, pending.count)
        let count = submitted.count
        lock.unlock()
        onSubmit(count)
    }

    func completeFirst(success: Bool = true) {
        lock.lock()
        let callback = pending.isEmpty ? nil : pending.removeFirst()
        lock.unlock()
        callback?(success, nil)
    }

    func snapshot() -> (requests: Int, submitted: [URL], peak: Int) {
        lock.lock(); defer { lock.unlock() }
        return (requests, submitted, peak)
    }
}

final class PhotoEffectsPhotosPublisherTests: XCTestCase {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try Data([1, 2, 3]).write(to: url)
        return url
    }

    func testTwoWorkersShareAuthorizationAndWaitForEachReceipt() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let firstSubmitted = expectation(description: "first Photos transaction")
        let secondSubmitted = expectation(description: "second Photos transaction")
        let client = HeldEffectsPhotoLibrary { count in
            if count == 1 { firstSubmitted.fulfill() }
            else if count == 2 { secondSubmitted.fulfill() }
        }
        let publisher = PhotoEffectsPhotosPublisher(importer: PhotoLibraryImporter(client: client))
        let first = Task { try await publisher.save(url) }
        await fulfillment(of: [firstSubmitted], timeout: 3)
        let second = Task { try await publisher.save(url) }
        client.completeFirst()
        try await first.value
        await fulfillment(of: [secondSubmitted], timeout: 3)
        client.completeFirst()
        try await second.value
        let state = client.snapshot()
        XCTAssertEqual(state.requests, 1)
        XCTAssertEqual(state.submitted.count, 2)
        XCTAssertEqual(state.peak, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testCancelledWaiterDoesNotSubmitAndActiveCommitKeepsRealResult() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let submitted = expectation(description: "active Photos transaction")
        let client = HeldEffectsPhotoLibrary { _ in submitted.fulfill() }
        let publisher = PhotoEffectsPhotosPublisher(importer: PhotoLibraryImporter(client: client))
        let active = Task { try await publisher.save(url) }
        await fulfillment(of: [submitted], timeout: 3)
        let started = expectation(description: "waiting caller started")
        let cancelled = expectation(description: "waiting caller cancelled before active receipt")
        let waiting = Task {
            started.fulfill()
            do { try await publisher.save(url); XCTFail("cancelled save submitted") }
            catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
            cancelled.fulfill()
        }
        await fulfillment(of: [started], timeout: 3)
        waiting.cancel()
        await fulfillment(of: [cancelled], timeout: 3)
        active.cancel() // PhotoKit cannot undo an already submitted transaction.
        client.completeFirst()
        try await active.value
        await waiting.value
        XCTAssertEqual(client.snapshot().submitted.count, 1)
    }

    func testFailedReceiptReleasesNextSave() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let submitted = expectation(description: "failed transaction submitted")
        let recovered = expectation(description: "next transaction submitted")
        let client = HeldEffectsPhotoLibrary { count in
            if count == 1 { submitted.fulfill() } else { recovered.fulfill() }
        }
        let publisher = PhotoEffectsPhotosPublisher(importer: PhotoLibraryImporter(client: client))
        let first = Task { try await publisher.save(url) }
        await fulfillment(of: [submitted], timeout: 3)
        let second = Task { try await publisher.save(url) }
        client.completeFirst(success: false)
        do { try await first.value; XCTFail("expected Photos failure") }
        catch PhotoLibraryImportError.importFailed {} catch { XCTFail("unexpected error: \(error)") }
        await fulfillment(of: [recovered], timeout: 3)
        client.completeFirst()
        try await second.value
        XCTAssertEqual(client.snapshot().peak, 1)
    }
}
