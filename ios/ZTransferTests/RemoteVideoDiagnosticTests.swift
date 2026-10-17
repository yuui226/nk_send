import XCTest
@testable import ZTransfer

final class RemoteVideoDiagnosticTests: XCTestCase {
    func testKnownHeadersExposeOnlyHeaderSlices() {
        for (operation, offset, slice) in [(UInt16(0x9203), 384, "64..68"), (0x9428, 512, "380..392"), (0x9428, 1024, "816..828")] {
            var payload = Data(repeating: 0, count: offset)
            payload.append(contentsOf: [0xFF, 0xD8, 0xFF, 0xDE, 0xAD, 0xBE, 0xEF])
            let report = RemoteVideoDiagnostic.report(operation: operation, response: 0x2001, payload: payload, model: "Z30")
            XCTAssertTrue(report.contains("video[\(slice)]=00000000"))
            XCTAssertTrue(report.contains("header=\(offset)"))
            XCTAssertFalse(report.contains("DEADBEEF"))
        }
    }

    func testUnknownAndTruncatedHeadersNeverGuessOffsets() {
        for payload in [Data(), Data([0xFF, 0xD8, 0xFF]), Data(repeating: 0, count: 2055)] {
            let report = RemoteVideoDiagnostic.report(operation: 0x9428, response: 0x2001, payload: payload, model: "Z30")
            XCTAssertTrue(report.contains("unknown video layout"))
            XCTAssertTrue(report.contains("header[0..31]=unavailable"))
            XCTAssertTrue(report.contains("remainingMs=null"))
        }
    }
}
