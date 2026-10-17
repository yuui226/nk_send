import XCTest
@testable import ZTransfer

final class RemoteLUTLoadQueueTests: XCTestCase {
    func testCancellationInvalidatesOlderResult() async {
        let queue = RemoteLUTLoadQueue()
        let first = Task { await queue.load(data: Data([1])) { _ in
            Thread.sleep(forTimeInterval: 0.05); return nil
        }}
        try? await Task.sleep(for: .milliseconds(5))
        let second = await queue.load(data: Data([2])) { data in
            data == Data([2]) ? try? CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 8)).utf8)) : nil
        }
        XCTAssertNotNil(second)
        let firstResult = await first.value
        XCTAssertNil(firstResult)
    }
    func testParsedCacheInvalidationAndBothCapacityLimits() throws {
        let table = try CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 8)).utf8))
        let stamp = ParsedLUTCache.Stamp(size: 100, modified: Date(timeIntervalSince1970: 1))
        for cache in [ParsedLUTCache(budget: 192), ParsedLUTCache(maxEntries: 2)] {
            cache.put("a", stamp: stamp, table: table)
            cache.put("b", stamp: stamp, table: table)
            XCTAssertEqual(cache.get("a", stamp: stamp), table)
            cache.put("c", stamp: stamp, table: table)
            XCTAssertNil(cache.get("b", stamp: stamp))
            XCTAssertEqual(cache.get("a", stamp: stamp), table)
            XCTAssertEqual(cache.get("c", stamp: stamp), table)
            XCTAssertNil(cache.get("a", stamp: .init(size: 100, modified: Date(timeIntervalSince1970: 2))))
            XCTAssertNil(cache.get("a", stamp: stamp))
            XCTAssertNil(cache.get("c", stamp: .init(size: nil, modified: stamp.modified)))
            cache.put("unknown", stamp: .init(size: 100, modified: nil), table: table)
            XCTAssertNil(cache.get("unknown", stamp: .init(size: 100, modified: nil)))
        }
        let tooSmall = ParsedLUTCache(budget: 95)
        tooSmall.put("a", stamp: stamp, table: table)
        XCTAssertNil(tooSmall.get("a", stamp: stamp))
    }

    func testCachedFileAlwaysRechecksMetadataAndDoesNotCacheMidReadEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("a.cube")
        let cache = ParsedLUTCache()
        let data = Data(("LUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 8)).utf8)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: url.path)
        var reads = 0
        func read(_ url: URL) throws -> Data {
            reads += 1
            return try RemoteLUTFolderAccess.readBounded(url)
        }
        let first = try RemoteLUTFolderAccess.parseFile(url, cache: cache, checkCancelled: {}, read: read)
        XCTAssertEqual(try RemoteLUTFolderAccess.parseFile(url, cache: cache, checkCancelled: {}, read: read), first)
        XCTAssertEqual(reads, 1)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: url.path)
        _ = try RemoteLUTFolderAccess.parseFile(url, cache: cache, checkCancelled: {}) { path in
            let result = try read(path)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 300)], ofItemAtPath: path.path)
            return result
        }
        XCTAssertEqual(reads, 2)
        _ = try RemoteLUTFolderAccess.parseFile(url, cache: cache, checkCancelled: {}, read: read)
        XCTAssertEqual(reads, 3, "File changed during read must not populate the cache")
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try RemoteLUTFolderAccess.parseFile(url, cache: cache, checkCancelled: {}, read: read))
        XCTAssertNil(cache.get(url.absoluteString, stamp: .init(size: Int64(data.count), modified: Date(timeIntervalSince1970: 300))))
    }

    func testRevokedScopeInvalidatesCachedTableBeforeRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = RemoteLUTFile(identifier: root.appendingPathComponent("a.cube").path,
                                 name: "a.cube", relativePath: "a.cube", size: 100)
        let key = URL(fileURLWithPath: file.identifier).absoluteString
        let table = try CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 8)).utf8))
        let cache = ParsedLUTCache()
        let stamp = ParsedLUTCache.Stamp(size: 100, modified: Date(timeIntervalSince1970: 1))
        let bookmark = try root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        cache.put(key, stamp: stamp, table: table)
        let denied = DirectoryAccessOperations(start: { _ in false }, stop: { _ in XCTFail("Denied scope must not be released") })
        XCTAssertThrowsError(try RemoteLUTFolderAccess.parseBookmark(bookmark, file: file, cache: cache,
                                                                   operations: denied, checkCancelled: {})) {
            XCTAssertEqual($0 as? RemoteLUTFolderAccessError, .denied)
        }
        XCTAssertNil(cache.get(key, stamp: stamp))
    }

    func testOversizedFileIsRejectedBeforeCacheHitOrByteRead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(CubeLUTParser.maxBytes + 1))
        try handle.close()
        let modified = Date(timeIntervalSince1970: 100)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        let stamp = ParsedLUTCache.Stamp(size: Int64(CubeLUTParser.maxBytes + 1), modified: modified)
        let table = try CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + String(repeating: "0 0 0\n", count: 8)).utf8))
        let cache = ParsedLUTCache()
        cache.put(url.absoluteString, stamp: stamp, table: table)
        XCTAssertThrowsError(try RemoteLUTFolderAccess.parseFile(url, cache: cache, checkCancelled: {}, read: { _ in
            XCTFail("Metadata limit must reject before reading bytes")
            return Data()
        })) { XCTAssertEqual($0 as? CubeLUTFailure, .tooLarge) }
        XCTAssertNil(cache.get(url.absoluteString, stamp: stamp))
    }

}
