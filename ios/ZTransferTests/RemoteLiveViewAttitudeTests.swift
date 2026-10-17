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

/// Android 1.97 ZfLiveViewFocusTest / MonitorRemainingTest boundary fixtures.
final class Remote197FrameTests: XCTestCase {
    private func put(_ value: UInt32, in bytes: inout [UInt8], at offset: Int, count: Int = 4) {
        for i in 0..<count { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> ((count - i - 1) * 8)) }
    }
    private func packet(size: Int = 1024, major: UInt32 = 2, minor: UInt32 = 1,
                        millis: UInt32 = 125_000, recording: UInt8 = 0) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: size + 3)
        put(major, in: &bytes, at: 0, count: 2); put(minor, in: &bytes, at: 2, count: 2)
        put(UInt32(size), in: &bytes, at: 8); put(3, in: &bytes, at: 12)
        for (offset, value): (Int, UInt32) in [(16, 6000), (18, 4000), (28, 640), (30, 424)] {
            put(value, in: &bytes, at: offset, count: 2)
        }
        put(millis, in: &bytes, at: size == 512 ? 384 : 816)
        bytes[size == 512 ? 392 : 828] = recording
        bytes[size] = 0xFF; bytes[size + 1] = 0xD8; bytes[size + 2] = 0xFF
        return bytes
    }
    func testZfV21UsesFullCoordinatesAndRejectsUnknownLayouts() throws {
        let bytes = packet()
        let value = try XCTUnwrap(RemoteFrameParser.metadata(from: Data(bytes), jpegOffset: 1024,
                                                             operation: PTPConstants.getLiveViewImageEx))
        XCTAssertEqual(value.trackingCoordinateWidth, 6000)
        XCTAssertEqual(value.trackingCoordinateHeight, 4000)
        XCTAssertEqual(value.focusCoordinateWidth, 640)
        XCTAssertEqual(value.remainingVideoTimeMs, 125_000)
        for (major, minor): (UInt32, UInt32) in [(2, 0), (2, 2), (3, 0)] {
            let invalid = packet(major: major, minor: minor)
            XCTAssertNil(RemoteFrameParser.metadata(from: Data(invalid), jpegOffset: 1024,
                                                      operation: PTPConstants.getLiveViewImageEx))
            XCTAssertNil(RemoteFrameParser.remainingVideoTime(in: invalid, headerSize: 1024))
        }
        XCTAssertNil(RemoteFrameParser.remainingVideoTime(in: packet(size: 512), headerSize: 512))
        for fraction: Float in [0.1, 0.5, 0.9] {
            XCTAssertEqual(rcNormalizedToFocusCoordinate(fraction, size: 6000),
                           Int((fraction * 5999).rounded()))
        }
    }
    func testEnhancedTimeSurvivesMissingAFGeometry() {
        for (size, major, minor): (Int, UInt32, UInt32) in [(512, 1, 0), (1024, 1, 0), (1024, 2, 1)] {
            var bytes = packet(size: size, major: major, minor: minor)
            put(0, in: &bytes, at: 16)
            XCTAssertNil(RemoteFrameParser.metadata(from: Data(bytes), jpegOffset: size,
                                                      operation: PTPConstants.getLiveViewImageEx))
            XCTAssertEqual(RemoteFrameParser.packetVideoTime(Data(bytes), jpegOffset: size,
                operation: PTPConstants.getLiveViewImageEx, model: nil), 125_000)
            bytes[12] = 1
            XCTAssertNil(RemoteFrameParser.packetVideoTime(Data(bytes), jpegOffset: size,
                operation: PTPConstants.getLiveViewImageEx, model: nil))
        }
    }
    func testLegacyModelGateAndZeroRecording() {
        var bytes = [UInt8](repeating: 0, count: 387)
        put(3, in: &bytes, at: 4); put(125_000, in: &bytes, at: 64)
        bytes[384] = 0xFF; bytes[385] = 0xD8; bytes[386] = 0xFF
        for model in ["Zf", "NIKON Z f", "Z 30"] {
            XCTAssertEqual(RemoteFrameParser.packetVideoTime(Data(bytes), jpegOffset: 384,
                operation: PTPConstants.getLiveViewImage, model: model), 125_000)
        }
        XCTAssertNil(RemoteFrameParser.packetVideoTime(Data(bytes), jpegOffset: 384,
            operation: PTPConstants.getLiveViewImage, model: "Z9"))
        put(0, in: &bytes, at: 64)
        XCTAssertNil(RemoteFrameParser.packetVideoTime(Data(bytes), jpegOffset: 384,
            operation: PTPConstants.getLiveViewImage, model: "Zf"))
        bytes[68] = 1
        XCTAssertEqual(RemoteFrameParser.packetVideoTime(Data(bytes), jpegOffset: 384,
            operation: PTPConstants.getLiveViewImage, model: "Zf"), 0)
    }
    func testMalformedOffsetsNeverReadOutOfBounds() {
        for size in [0, 1, 383, 384, 386, 511, 512, 514, 1023, 1024, 1026] {
            for offset in [Int.min, -1, 0, 376, 384, 512, 1024, Int.max] {
                XCTAssertNil(RemoteFrameParser.packetVideoTime(Data(repeating: 0, count: size),
                    jpegOffset: offset, operation: PTPConstants.getLiveViewImage, model: "Zf"))
            }
        }
    }
}
