import XCTest
import CoreGraphics
@testable import ZTransfer

final class RemoteExposureAnalysisTests: XCTestCase {
    func testAnalysisBitmapPreservesARGBChannelsAndRejectsInvalidDimensions() throws {
        let pixels: [UInt32] = [0xFF6B39B8, 0x807FFF00, 0, 0x40DCEBE3]
        let image = try XCTUnwrap(RemoteExposureAnalysis.image(pixels: pixels, width: 2, height: 2))
        let data = try XCTUnwrap(image.dataProvider?.data)
        XCTAssertEqual(Array(data as Data), [UInt8](arrayLiteral:
            0x6B,0x39,0xB8,0xFF, 0x7F,0xFF,0,0x80, 0,0,0,0, 0xDC,0xEB,0xE3,0x40))
        XCTAssertEqual(image.alphaInfo, .last)
        XCTAssertNil(RemoteExposureAnalysis.image(pixels: pixels, width: 0, height: 2))
        XCTAssertNil(RemoteExposureAnalysis.image(pixels: pixels, width: 3, height: 2))
        XCTAssertNil(RemoteExposureAnalysis.image(pixels: pixels, width: Int.max, height: Int.max))
    }

    func testSoundMeterSeparatesCurrentBarFromSinglePeak() {
        let silent = RemoteSoundMeterChannel(current: 0, peak: 0)
        XCTAssertEqual(silent.activeCount, 0)
        XCTAssertNil(silent.peakIndex)
        let low = RemoteSoundMeterChannel(current: 7, peak: 12)
        XCTAssertEqual(low.activeCount, 8)
        XCTAssertEqual(low.peakIndex, 12)
        let high = RemoteSoundMeterChannel(current: 14, peak: 3)
        XCTAssertEqual(high.activeCount, 15)
        XCTAssertEqual(high.peakIndex, 3)
        XCTAssertEqual(RemoteSoundMeterChannel(current: -1, peak: -1), silent)
        XCTAssertEqual(RemoteSoundMeterChannel(current: 99, peak: 99).activeCount, 15)
        XCTAssertEqual(RemoteSoundMeterChannel(current: 99, peak: 99).peakIndex, 14)
    }

    func testWaveformDensityIsIndependentOfOtherPeaksAndCombinesRGB() {
        var red = [Int](repeating: 0, count: 256 * 128)
        red[0] = 1
        red[1] = 15
        let first = RemoteExposureAnalysis.waveformPixels(channels: [red], sampleHeight: 15)
        red[1] = 3
        let second = RemoteExposureAnalysis.waveformPixels(channels: [red], sampleHeight: 15)
        XCTAssertEqual(first[0], 0x40DCEBE3)
        XCTAssertEqual(first[0], second[0])
        XCTAssertEqual(first[1], 0xFFDCEBE3)
        XCTAssertEqual(second[1], 0x80DCEBE3)
        var green = [Int](repeating: 0, count: red.count)
        green[0] = 3
        let blue = [Int](repeating: 0, count: red.count)
        let rgb = RemoteExposureAnalysis.waveformPixels(channels: [red, green, blue], sampleHeight: 15)
        XCTAssertEqual(rgb[0], 0x807FFF00)
        XCTAssertEqual(rgb[2], 0)
    }

    func testLumaUsesAndroidMonitorIntegerWeights() {
        XCTAssertEqual(RemoteExposureAnalysis.luma(red: 255, green: 0, blue: 0), 76)
        XCTAssertEqual(RemoteExposureAnalysis.luma(red: 0, green: 255, blue: 0), 149)
        XCTAssertEqual(RemoteExposureAnalysis.luma(red: 0, green: 0, blue: 255), 28)
    }

    func testColoredPixelsOnBothSidesOfEveryFalseColorThreshold() {
        let cases: [(UInt8, UInt32)] = [
            (12, 0xFF6B39B8), (13, 0xFF2874D7), (37, 0xFF2874D7), (38, 0xFF50555B),
            (101, 0xFF50555B), (102, 0xFF5ABE87), (114, 0xFF5ABE87), (115, 0xFFE792AE),
            (139, 0xFFE792AE), (140, 0xFFB9BDC2), (203, 0xFFB9BDC2), (204, 0xFFF0D55D),
            (241, 0xFFF0D55D), (242, 0xFFF14D4D)
        ]
        for (value, color) in cases {
            // Unequal channels straddle the same boundaries after Android integer truncation.
            XCTAssertEqual(RemoteExposureAnalysis.falseColor(red: value + 1, green: value, blue: value - 1), color)
        }
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
        XCTAssertEqual(bins[0][90 * 256 + 0], 1) // red luma 76
        XCTAssertEqual(bins[0][53 * 256 + 64], 1) // green luma 149
        XCTAssertEqual(bins[0][114 * 256 + 128], 1) // blue luma 28
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
