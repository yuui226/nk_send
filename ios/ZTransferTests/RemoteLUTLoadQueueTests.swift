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
}
