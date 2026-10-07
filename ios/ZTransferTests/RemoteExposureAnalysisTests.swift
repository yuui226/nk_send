import XCTest
@testable import ZTransfer

final class RemoteExposureAnalysisTests: XCTestCase {
    func testLumaUsesAndroidRec709IntegerWeights() {
        XCTAssertEqual(RemoteExposureAnalysis.luma(red: 255, green: 0, blue: 0), 53)
        XCTAssertEqual(RemoteExposureAnalysis.luma(red: 0, green: 255, blue: 0), 182)
        XCTAssertEqual(RemoteExposureAnalysis.luma(red: 0, green: 0, blue: 255), 18)
    }

    func testFalseColorThresholdsMatchAndroid() {
        let cases: [(Int, UInt32)] = [
            (0, 0xFF6B39B8), (12, 0xFF6B39B8), (13, 0xFF2874D7),
            (37, 0xFF2874D7), (38, 0xFF50555B), (101, 0xFF50555B),
            (102, 0xFF5ABE87), (114, 0xFF5ABE87), (115, 0xFFE792AE),
            (139, 0xFFE792AE), (140, 0xFFB9BDC2), (203, 0xFFB9BDC2),
            (204, 0xFFF0D55D), (241, 0xFFF0D55D), (242, 0xFFF14D4D),
            (255, 0xFFF14D4D)
        ]
        for (luma, color) in cases {
            XCTAssertEqual(RemoteExposureAnalysis.falseColor(forLuma: luma), color, "luma=\(luma)")
        }
    }

    func testWaveformUsesBottomOriginAndNearestColumns() {
        let bins = RemoteExposureAnalysis.waveformBins(
            pixels: [0x00FF0000, 0x0000FF00, 0x000000FF, 0x00FFFFFF],
            width: 4, height: 1, rgb: false
        )
        XCTAssertEqual(bins.count, 1)
        XCTAssertEqual(bins[0][101 * 256 + 0], 1) // red luma 53
        XCTAssertEqual(bins[0][37 * 256 + 64], 1) // green luma 182
        XCTAssertEqual(bins[0][119 * 256 + 128], 1) // blue luma 18
        XCTAssertEqual(bins[0][0 * 256 + 192], 1) // white luma 255
    }

    func testRgbWaveformKeepsSeparateChannelsAndLogDensity() {
        let bins = RemoteExposureAnalysis.waveformBins(pixels: [0x00FF0000], width: 1, height: 1, rgb: true)
        XCTAssertEqual(bins.count, 3)
        XCTAssertEqual(bins[0][0 * 256], 1)
        XCTAssertEqual(bins[1][127 * 256], 1)
        XCTAssertEqual(bins[2][127 * 256], 1)
        XCTAssertEqual(RemoteExposureAnalysis.waveformAlpha(count: 0, sampleHeight: 1), 0)
        XCTAssertEqual(RemoteExposureAnalysis.waveformAlpha(count: 1, sampleHeight: 1), 255)
    }

    func testFalseColorPixelsMapsEveryPixelWithoutMutatingSource() {
        let source: [UInt32] = [0x00FF0000, 0x0000FF00, 0x000000FF, 0x00FFFFFF]
        let copy = source
        XCTAssertEqual(RemoteExposureAnalysis.falseColorPixels(pixels: source, width: 2, height: 2), [
            0xFF50555B, 0xFFB9BDC2, 0xFF2874D7, 0xFFF14D4D
        ])
        XCTAssertEqual(source, copy)
        XCTAssertNil(RemoteExposureAnalysis.falseColorPixels(pixels: [1], width: 0, height: 1))
    }
}
