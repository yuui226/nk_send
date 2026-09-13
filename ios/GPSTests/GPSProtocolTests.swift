import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import ZTransferGPS
#else
@testable import ZTransfer
#endif

final class GPSProtocolTests: XCTestCase {
    func testPairingMatchesAndroidCapturedVector() {
        let first = NikonGPSPairingPacket(stage: 1, timestamp: 0x677da144ec13e1db,
                                          device: 0x3c3ae501, nonce: 0x3fdaa451)
        let second = NikonGPSPairingPacket(stage: 2, timestamp: 0xb9943d5e8026fa29,
                                           device: 0xa8b3f2e4, nonce: 0x16d56a13)
        let third = NikonGPSPairingProtocol().stage3(for: first, stage2: second)
        XCTAssertEqual(third?.device, 0x79f1ad53)
        XCTAssertEqual(third?.nonce, 0x23838a35)
    }

    func testGeoPayloadMatchesAndroidFieldLayout() {
        let payload = NikonGeoPayloadEncoder.encode(
            latitude: 39.9042, longitude: -116.4074, altitudeMeters: -12.5,
            satellites: 14, timestamp: Date(timeIntervalSince1970: 1_735_787_045))
        guard let payload else { return XCTFail("payload rejected") }
        XCTAssertEqual(payload.count, 41)
        XCTAssertEqual(payload[2], 78)
        XCTAssertEqual(payload[3], 39)
        XCTAssertEqual(payload[4], 54)
        XCTAssertEqual(payload[7], 87)
        XCTAssertEqual(payload[8], 116)
        XCTAssertEqual(payload[9], 24)
        XCTAssertEqual(payload[12], 14)
        XCTAssertEqual(payload[13], 77)
        XCTAssertEqual(UInt16(payload[14]) | UInt16(payload[15]) << 8, 12)
        XCTAssertEqual(String(decoding: payload[25..<31], as: UTF8.self), "WGS-84")
    }
}
