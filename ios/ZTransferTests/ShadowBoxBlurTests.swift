import XCTest
import CryptoKit
@testable import ZTransfer

final class ShadowBoxBlurTests: XCTestCase {
    func testNormalA8BoxBlurMatchesOriginalSkiaBytes() throws {
        struct Case: Decodable {
            let sigma: Double
            let width, height, pattern, outWidth, outHeight, border: Int
            let sha256: String
        }
        struct Reference: Decodable { let cases: [Case] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "android15-shadow-box-blur", withExtension: "json"))
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        XCTAssertEqual(reference.cases.count, 72)
        for test in reference.cases {
            var pixels: [UInt8] = []
            for y in 0..<test.height { for x in 0..<test.width {
                switch test.pattern {
                case 0: pixels.append(255)
                case 1: pixels.append(x == test.width / 2 && y == test.height / 2 ? 255 : 0)
                default: pixels.append(UInt8((x * 71 + y * 37 + 83) % 256))
                }
            } }
            let result = try ZTransferShadowBoxBlur.filterNormal(pixels, width: test.width, height: test.height,
                sigma: test.sigma, maximumWorkingBytes: 4 * 1024 * 1024)
            XCTAssertEqual(result.width, test.outWidth)
            XCTAssertEqual(result.height, test.outHeight)
            XCTAssertEqual(result.border, test.border)
            let hash = SHA256.hash(data: Data(result.pixels)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hash, test.sha256, "sigma \(test.sigma), \(test.width)x\(test.height), pattern \(test.pattern)")
        }
    }

    func testSmallA8BlurMatchesOriginalSkiaFactorsAndBytes() throws {
        struct Case: Decodable {
            let sigma: Double
            let width, height, pattern, outWidth, outHeight, border: Int
            let factors: [UInt16]
            let sha256: String
        }
        struct Reference: Decodable { let cases: [Case] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "android15-shadow-small-blur", withExtension: "json"))
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        XCTAssertEqual(reference.cases.count, 162)
        for test in reference.cases {
            XCTAssertEqual(ZTransferShadowBoxBlur.smallFactors(sigma: test.sigma), test.factors)
            var pixels: [UInt8] = []
            for y in 0..<test.height { for x in 0..<test.width {
                switch test.pattern {
                case 0: pixels.append(255)
                case 1: pixels.append(x == test.width / 2 && y == test.height / 2 ? 255 : 0)
                default: pixels.append(UInt8((x * 71 + y * 37 + 83) % 256))
                }
            } }
            let result = try ZTransferShadowBoxBlur.filterNormal(pixels, width: test.width, height: test.height,
                sigma: test.sigma, maximumWorkingBytes: 1024 * 1024)
            XCTAssertEqual(result.width, test.outWidth)
            XCTAssertEqual(result.height, test.outHeight)
            XCTAssertEqual(result.border, test.border)
            let hash = SHA256.hash(data: Data(result.pixels)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hash, test.sha256, "sigma \(test.sigma), \(test.width)x\(test.height), pattern \(test.pattern)")
        }
        for sigma: Double in [-1, 0, 1.0 / 3, 2, .nan, .infinity] {
            XCTAssertNil(ZTransferShadowBoxBlur.smallFactors(sigma: sigma))
            XCTAssertThrowsError(try ZTransferShadowBoxBlur.filterSmall([255], width: 1, height: 1,
                sigma: sigma, maximumWorkingBytes: 1024))
        }
        XCTAssertThrowsError(try ZTransferShadowBoxBlur.filterSmall([255], width: 1, height: 1,
            sigma: 1.5, maximumWorkingBytes: 1))
    }

    func testNormalSoftwareIdentityBoundary() throws {
        let pixels: [UInt8] = [0, 1, 127, 128, 254, 255]
        for sigma: Double in [0, 0.03, 0.125, 1.0 / 3, (1.0 / 3).nextUp] {
            let result = try ZTransferShadowBoxBlur.filterNormal(pixels, width: 3, height: 2,
                sigma: sigma, maximumWorkingBytes: 0)
            XCTAssertEqual(result.pixels, pixels)
            XCTAssertEqual(result.border, 0)
            XCTAssertEqual(result.width, 3)
            XCTAssertEqual(result.height, 2)
        }
        // The first neighbor still has 3*sigma rounded to exactly one.
        XCTAssertEqual(3 * (1.0 / 3).nextUp, 1)
        let firstBlur = (1.0 / 3).nextUp.nextUp
        XCTAssertGreaterThan(3 * firstBlur, 1)
        let blurred = try ZTransferShadowBoxBlur.filterNormal(pixels, width: 3, height: 2,
            sigma: firstBlur, maximumWorkingBytes: 1024)
        XCTAssertGreaterThan(blurred.border, 0)
        XCTAssertThrowsError(try ZTransferShadowBoxBlur.filterNormal([], width: 0, height: 0, sigma: 0, maximumWorkingBytes: 0))
    }

    func testRejectsUnsupportedSigmaAndWorkingSetBeforeAllocation() throws {
        for sigma: Double in [-1, 0, 1.999, 136, .infinity, .nan] {
            XCTAssertThrowsError(try ZTransferShadowBoxBlur.filter([255], width: 1, height: 1, sigma: sigma,
                maximumWorkingBytes: 4 * 1024 * 1024))
        }
        XCTAssertThrowsError(try ZTransferShadowBoxBlur.filter([255], width: 2, height: 1, sigma: 2, maximumWorkingBytes: 1024))
        XCTAssertThrowsError(try ZTransferShadowBoxBlur.filter([255], width: 1, height: 1, sigma: 135, maximumWorkingBytes: 32)) { error in
            guard case ZTransferShadowBoxBlur.Failure.workingSetExceeded = error else { return XCTFail("wrong failure: \(error)") }
        }
    }
}
