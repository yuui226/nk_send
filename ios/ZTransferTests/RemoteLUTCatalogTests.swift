import XCTest
@testable import ZTransfer

final class RemoteLUTCatalogTests: XCTestCase {
    func testRootAndOneCategoryCubeFilesOnly() {
        let input = [
            RemoteLUTFile(identifier: "deep", name: "deep.cube", relativePath: "film/2026/deep.cube", size: 1),
            RemoteLUTFile(identifier: "txt", name: "readme.txt", relativePath: "readme.txt", size: 1),
            RemoteLUTFile(identifier: "b", name: "B.CUBE", relativePath: "film/B.CUBE", size: 1),
            RemoteLUTFile(identifier: "a", name: "a.cube", relativePath: "a.cube", size: 1)
        ]
        XCTAssertEqual(RemoteLUTCatalog.visibleFiles(input).map(\.identifier), ["a", "b"])
    }
}
