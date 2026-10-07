import SwiftUI
import UIKit
import XCTest
@testable import ZTransfer

final class AndroidColorInterpolationTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Sample: Decodable {
            let start: String
            let end: String
            let fraction: Float
            let result: String
        }
        let samples: [Sample]
    }

    private func samples() throws -> [Fixture.Sample] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "AndroidColorInterpolation", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).samples
    }

    func testEveryReferenceColorMatchesResolvedComposeLibrary() throws {
        let samples = try samples()
        XCTAssertEqual(samples.count, 156)
        for sample in samples {
            let result = ZTransferAndroidColor.lerp(
                start: try XCTUnwrap(UInt32(sample.start, radix: 16)),
                end: try XCTUnwrap(UInt32(sample.end, radix: 16)), fraction: sample.fraction)
            XCTAssertEqual(result, UInt32(sample.result, radix: 16),
                "\(sample.start) -> \(sample.end), fraction=\(sample.fraction), actual=\(String(result, radix: 16))")
        }
    }

    @MainActor
    func testActualCameraInkUsesComposeInterpolation() throws {
        for scheme in [ColorScheme.dark, .light] {
            let end = scheme == .dark ? "ff4fc3f7" : "ff0277bd"
            let expected = try XCTUnwrap(try samples().first {
                $0.start == "ffd5d8da" && $0.end == end && $0.fraction == 0.72
            })
            let color = zTransferMaterialContentColor(skin: .cameraControls, scheme: scheme,
                fallback: .red, active: true, activeColor: ZTransferColors.accentBlue)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a))
            XCTAssertEqual(ZTransferAndroidColor.pack(red: Float(r), green: Float(g), blue: Float(b), alpha: Float(a)),
                           UInt32(expected.result, radix: 16))
        }
    }

    @MainActor
    func testAnimatedCameraInkRecomputesOklabAtIntermediateProgress() throws {
        let reference = try samples()
        var modifier = ZTransferCameraPrint(scheme: .dark, inlay: nil,
            activeColor: ZTransferColors.accentBlue, progress: 0)
        for (progress, fraction) in [(CGFloat(0), Float(0)), (0.5, 0.36), (1, 0.72)] {
            modifier.animatableData = progress
            let expected = try XCTUnwrap(reference.first {
                $0.start == "ffd5d8da" && $0.end == "ff4fc3f7" && $0.fraction == fraction
            })
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(UIColor(modifier.resolvedInk).getRed(&r, green: &g, blue: &b, alpha: &a))
            XCTAssertEqual(ZTransferAndroidColor.pack(red: Float(r), green: Float(g), blue: Float(b), alpha: Float(a)),
                           UInt32(expected.result, radix: 16), "progress=\(progress)")
        }
    }
}
