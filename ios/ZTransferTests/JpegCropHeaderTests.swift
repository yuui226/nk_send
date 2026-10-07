import XCTest
@testable import ZTransfer

final class JpegCropHeaderTests: XCTestCase {
    func testReadsSOFDimensionsAndSampling() {
        let bytes: [UInt8] = [0xff,0xd8, 0xff,0xc0, 0,17, 8, 0x01,0x00, 0x02,0x00, 3, 1,0x22,0, 2,0x11,0, 3,0x11,0, 0xff,0xda]
        let source = parseJpegCropHeader(Data(bytes))
        XCTAssertEqual(source?.width, 512); XCTAssertEqual(source?.height, 256)
        XCTAssertEqual(source?.mcuWidth, 16); XCTAssertEqual(source?.mcuHeight, 16)
    }

}
