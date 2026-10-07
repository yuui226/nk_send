import XCTest
@testable import ZTransfer

/// All five LiveViewAttitudeTest cases, with the captured Android/Z30 samples.
final class RemoteLiveViewAttitudeTests: XCTestCase {
    private func header(_ roll: UInt32, _ pitch: UInt32, alternate: UInt32 = 0) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 512)
        bytes[1] = 1; bytes[10] = 2
        for (offset, value) in [(404, roll), (408, pitch), (412, alternate)] {
            for i in 0..<4 { bytes[offset+i] = UInt8(truncatingIfNeeded: value >> (24-i*8)) }
        }
        return bytes
    }
    private func parse(_ roll: UInt32, _ pitch: UInt32, alternate: UInt32 = 0) -> RemoteLiveViewAttitude? {
        RemoteFrameParser.compactAttitude(in: header(roll, pitch, alternate: alternate), headerSize: 512)
    }
    func testCapturedZ30Poses() throws {
        let samples: [(UInt32, UInt32, Float)] = [(0x01676677, 0x0166ffb3, -1),
            (0x01677341, 0x000f553f, 15.333), (0x0163f3c2, 0x015befc2, -12.063), (0x0011f5c9, 0x0164f252, -3.053)]
        for (roll, pitch, expected) in samples {
            XCTAssertEqual(try XCTUnwrap(parse(roll, pitch)).pitch, expected, accuracy: 0.01)
        }
        XCTAssertEqual(try XCTUnwrap(parse(0x0011f5c9, 0x0164f252)).roll, 17.96, accuracy: 0.01)
    }
    func testPortraitRequiresExplicitUnavailablePrimaryAxis() throws {
        let samples: [(UInt32, UInt32, Float)] = [(0x00591980, 0x01670000, -1),
            (0x0055cc3c, 0x0013c2ce, 19.761), (0x005a4cce, 0x0153c000, -20.25)]
        for (roll, pitch, expected) in samples {
            let value = try XCTUnwrap(parse(roll, .max, alternate: pitch))
            XCTAssertEqual(value.pitch, expected, accuracy: 0.01)
            XCTAssertEqual(value.roll, Float(roll) / 65536, accuracy: 0.001)
        }
        XCTAssertNil(parse(90 * 65536, .max, alternate: .max))
        XCTAssertNil(parse(0, .max, alternate: 65536))
        var invalid = header(90 * 65536, .max, alternate: 65536)
        invalid[408] = 0x7f
        XCTAssertNil(RemoteFrameParser.compactAttitude(in: invalid, headerSize: 512))
    }
    func testReversePortraitUses180NeutralAndInvertedPitch() throws {
        let samples: [(UInt32, UInt32, Float)] = [(0x010f0cb7, 0x00b33351, 0.8),
            (0x010aa67d, 0x009c768d, 23.537), (0x010e0cdc, 0x00c30000, -15)]
        for (roll, pitch, expected) in samples {
            let value = try XCTUnwrap(parse(roll, .max, alternate: pitch))
            XCTAssertEqual(value.pitch, expected, accuracy: 0.01)
            XCTAssertEqual(value.roll, Float(roll) / 65536 - 360, accuracy: 0.001)
        }
        XCTAssertEqual(try XCTUnwrap(parse(270 * 65536, .max, alternate: 180 * 65536)).pitch, 0)
        XCTAssertNil(parse(270 * 65536, .max, alternate: .max))
        XCTAssertNil(parse(270 * 65536, .max, alternate: 0))
    }
    func testInvertedLandscapeUsesPrimaryAxisWith180Neutral() throws {
        let samples: [(UInt32, UInt32, Float)] = [(0x00b6f33f, 0x00b34002, 0.75),
            (0x00b34cd9, 0x00a30ccf, 16.95), (0x00b2f33f, 0x00ca3334, -22.2)]
        for (roll, pitch, expected) in samples {
            XCTAssertEqual(try XCTUnwrap(parse(roll, pitch, alternate: .max)).pitch, expected, accuracy: 0.01)
        }
        XCTAssertEqual(try XCTUnwrap(parse(180 * 65536, 180 * 65536, alternate: .max)).pitch, 0)
        XCTAssertNil(parse(180 * 65536, .max, alternate: .max))
        XCTAssertNil(parse(180 * 65536, 0, alternate: .max))
    }
    func testUnknownLayoutsAndReservedValuesDoNotCreateFalseLevel() {
        XCTAssertNil(parse(0, 0))
        XCTAssertNil(parse(.max, 0))
        XCTAssertNil(parse(1, 120 * 65536))
        XCTAssertNil(RemoteFrameParser.compactAttitude(in: header(1, 1), headerSize: 1024))
        var invalid = header(1, 1); invalid[1] = 2
        XCTAssertNil(RemoteFrameParser.compactAttitude(in: invalid, headerSize: 512))
        XCTAssertNil(RemoteFrameParser.compactAttitude(in: [UInt8](repeating: 0, count: 100), headerSize: 512))
        XCTAssertNotNil(parse(0, 65536))
    }
}
