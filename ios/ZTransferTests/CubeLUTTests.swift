import XCTest
@testable import ZTransfer

final class CubeLUTTests: XCTestCase {
    private func cube(_ body: String = "") -> Data {
        Data(("LUT_3D_SIZE 2\n" + body + (0..<8).map { _ in "0 0 0\n" }.joined()).utf8)
    }

    func testParsesDefaultsAndRFastestData() throws {
        let lut = try CubeLUTParser.parse(cube())
        XCTAssertEqual(lut.size, 2)
        XCTAssertEqual(lut.domainMin, SIMD3(repeating: 0))
        XCTAssertEqual(lut.domainMax, SIMD3(repeating: 1))
        XCTAssertEqual(lut.rgb.count, 24)
        XCTAssertEqual(lut.digest.count, 64)
        XCTAssertEqual(lut.rgba16FloatUploadValues.count, 32)
        XCTAssertEqual(lut.rgba16FloatUploadValues[3], Float16(1))
    }

    func testParsesDomainAndRejectsMalformedBounds() throws {
        let lut = try CubeLUTParser.parse(cube("DOMAIN_MIN -0.1 0 0\nDOMAIN_MAX 1.2 1 1\n"))
        XCTAssertEqual(lut.domainMin.x, -0.1, accuracy: 0.0001)
        XCTAssertThrowsError(try CubeLUTParser.parse(cube("DOMAIN_MIN 1 0 0\nDOMAIN_MAX 0 1 1\n")))
    }

    func testRejectsIncompleteUnsupportedAndOversizedLines() {
        XCTAssertThrowsError(try CubeLUTParser.parse(Data("LUT_3D_SIZE 2\n0 0\n".utf8)))
        XCTAssertThrowsError(try CubeLUTParser.parse(Data("LUT_3D_SIZE 1\n".utf8)))
        XCTAssertThrowsError(try CubeLUTParser.parse(Data(("#" + String(repeating: "x", count: CubeLUTParser.maxLine + 1)).utf8)))
    }

    func testTrilinearSamplingUsesRFastestIndexAndClampsDomain() throws {
        let rows = (0..<8).map { index -> String in
            let r = Float(index & 1), g = Float((index >> 1) & 1), b = Float((index >> 2) & 1)
            return "\(r) \(g) \(b)\n"
        }.joined()
        let lut = try CubeLUTParser.parse(Data(("LUT_3D_SIZE 2\n" + rows).utf8))
        let midpoint = lut.sample(SIMD3<Float>(0.25, 0.5, 0.75))
        XCTAssertEqual(midpoint.x, 0.25, accuracy: 0.0001); XCTAssertEqual(midpoint.y, 0.5, accuracy: 0.0001); XCTAssertEqual(midpoint.z, 0.75, accuracy: 0.0001)
        let clamped = lut.sample(SIMD3<Float>(-1, 2, 1))
        XCTAssertEqual(clamped.x, 0, accuracy: 0.0001); XCTAssertEqual(clamped.y, 1, accuracy: 0.0001); XCTAssertEqual(clamped.z, 1, accuracy: 0.0001)
    }

    func testRejectsValuesOutsideRGBA16FRange() {
        let source = "LUT_3D_SIZE 2\n" + Array(repeating: "70000 0 0\n", count: 8).joined()
        XCTAssertThrowsError(try CubeLUTParser.parse(Data(source.utf8))) { error in
            XCTAssertEqual(error as? CubeLUTFailure, .invalid)
        }
    }

    func testRejectsGpuUnrepresentableDomain() {
        let source = "DOMAIN_MIN 0.00000000000000000000000000000000000001 0 0\n" +
            "LUT_3D_SIZE 2\n" + Array(repeating: "0 0 0\n", count: 8).joined()
        XCTAssertThrowsError(try CubeLUTParser.parse(Data(source.utf8)))
    }
}
