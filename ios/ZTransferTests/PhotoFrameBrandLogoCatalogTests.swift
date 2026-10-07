import XCTest
@testable import ZTransfer

final class PhotoFrameBrandLogoCatalogTests: XCTestCase {
    private func path(_ data: String) -> CGPath? {
        PhotoFrameBrandLogoAsset(brand: .apple,
            viewBox: CGRect(x: 0, y: 0, width: 24, height: 24), pathData: data).makePath()
    }

    // Android BrandLogoPathsTest requires every selected runtime path to parse.
    func testAllSelectedResourcePaths() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for brand in PhotoFrameBrand.allCases {
            let url = root.appendingPathComponent("ZTransfer/Resources/BrandLogos/\(brand.rawValue).svg")
            let xml = try String(contentsOf: url, encoding: .utf8)
            let range = try XCTUnwrap(xml.range(of: #"d="([^"]+)""#, options: .regularExpression))
            let data = String(xml[range].dropFirst(3).dropLast())
            let parsed = try XCTUnwrap(path(data), brand.rawValue)
            XCTAssertFalse(parsed.boundingBoxOfPath.isEmpty, brand.rawValue)
        }
    }

    func testArcEndpointsDegeneracyAndFlags() {
        XCTAssertEqual(path("M0 0A10 10 0 0 1 20 0")?.currentPoint, CGPoint(x: 20, y: 0))
        XCTAssertEqual(path("M0 0a0 10 0 0 1 20 0")?.currentPoint, CGPoint(x: 20, y: 0))
        XCTAssertNil(path("M0 0A10 10 0 2 1 20 0"))
    }

    func testCompactNumbersAndExponents() {
        XCTAssertEqual(path("M1 2l3-1.5.5 2")?.currentPoint, CGPoint(x: 4.5, y: 2.5))
        XCTAssertEqual(path("M1e1 2E0H12V4")?.currentPoint, CGPoint(x: 12, y: 4))
    }

    func testSmoothCubicReflectsPreviousControl() {
        var controls: [CGPoint] = []
        path("M0 0C1 2 3 4 5 6s2 3 4 5")?.applyWithBlock { element in
            if element.pointee.type == .addCurveToPoint { controls.append(element.pointee.points[0]) }
        }
        XCTAssertEqual(controls, [CGPoint(x: 1, y: 2), CGPoint(x: 7, y: 8)])
    }

    func testMalformedInputTerminatesWithoutPartialPath() {
        XCTAssertNil(path("M0 0Z1 2"))
        XCTAssertNil(path("M0 0L@1 2"))
        XCTAssertNil(path(""))
    }
}
