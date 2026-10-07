import XCTest
@testable import ZTransfer

final class RemoteHorizonColorReferenceTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Sample: Decodable {
            let start: String
            let end: String
            let interruptedAtMs: Int64
            let timeMs: Int64
            let result: String
        }
        let samples: [Sample]
    }
    func testFramesAndInterruptedFramesMatchComposeColorVectorAnimation() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "AndroidHorizonColors", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.samples.count, 64)
        for sample in fixture.samples {
            let start = try XCTUnwrap(UInt32(sample.start, radix: 16))
            let end = try XCTUnwrap(UInt32(sample.end, radix: 16))
            var animation = RemoteHorizonColorAnimation(start)
            animation.retarget(end)
            animation.advance(0)
            if sample.interruptedAtMs != 0 {
                animation.advance(sample.interruptedAtMs * 1_000_000)
                animation.retarget(start)
            }
            animation.advance((sample.interruptedAtMs + sample.timeMs) * 1_000_000)
            XCTAssertEqual(animation.value, UInt32(sample.result, radix: 16),
                "\(sample.start)->\(sample.end) interruption=\(sample.interruptedAtMs) time=\(sample.timeMs) actual=\(String(animation.value, radix: 16))")
        }
    }
}
