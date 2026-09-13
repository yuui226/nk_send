import XCTest
import CryptoKit
#if SWIFT_PACKAGE
@testable import ZTransferEffects
#else
@testable import ZTransfer
#endif

final class Np3FilterEngineTests: XCTestCase {
    func testCatalogHasFiftyDistinctAndroidIdentitiesAndLegacyMappings() {
        let presets = Np3FilterCatalog.presets
        XCTAssertEqual(presets.count, 50)
        XCTAssertEqual(Set(presets.map(\.id)).count, 50)
        XCTAssertEqual(Set(presets.map(\.catalogKey)).count, 50)
        XCTAssertEqual(Set(presets.map(\.legacyID)).count, 50)
        XCTAssertEqual(presets.filter { $0.parameters.toneCurve != nil }.count, 21)
        for preset in presets {
            let source = Data("\(preset.catalogKey)|np3-srgb-v1".utf8)
            XCTAssertEqual(preset.id, SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined())
            XCTAssertEqual(Np3FilterCatalog.preset(id: preset.id), preset)
            XCTAssertEqual(Np3FilterCatalog.preset(id: preset.catalogKey), preset)
            XCTAssertEqual(Np3FilterCatalog.preset(id: preset.legacyID), preset)
            XCTAssertEqual(preset.parameters.colorBands.map(\.centerDegrees), [0, 30, 60, 120, 180, 240, 280, 320])
        }
        for left in presets.indices {
            for right in presets.indices where right > left {
                XCTAssertNotEqual(presets[left].parameters, presets[right].parameters)
            }
        }
        XCTAssertNil(Np3FilterCatalog.preset(id: "unknown"))
    }

    /// Values and curve hashes are copied from Android BuiltInPhotoFiltersTest.
    func testRepresentativeSourceControlsAndCurvesRemainStable() throws {
        let mono = try XCTUnwrap(Np3FilterCatalog.preset(id: "british_mono"))
        let cinema = try XCTUnwrap(Np3FilterCatalog.preset(id: "cinema_blue"))
        let portrait = try XCTUnwrap(Np3FilterCatalog.preset(id: "soft_portrait"))
        XCTAssertEqual(mono.id, "644e9710e38197be33257f0562f89dc3882642e36be6d2b295f82f813597a6d7")
        XCTAssertEqual(cinema.id, "079ca263bcef213f804aa4f49b3d3a4570828647c4d8563860f147d2128ee778")
        XCTAssertEqual(portrait.id, "a247d4033b0c11acb864dcf03c7355d213e39e81c4030bedb71067e7ca5f14f7")
        XCTAssertEqual([mono.parameters.contrast, mono.parameters.highlights, mono.parameters.shadows,
                        mono.parameters.whites, mono.parameters.blacks, mono.parameters.saturation],
                       [3, -20, 31, -34, -10, -98])
        XCTAssertNil(mono.parameters.toneCurve)
        XCTAssertEqual(cinema.parameters.saturation, -5)
        XCTAssertEqual(cinema.parameters.colorBands[4].chroma, 78)
        XCTAssertEqual(cinema.parameters.colorBands[5].chroma, 100)
        XCTAssertEqual(curveHash(try XCTUnwrap(cinema.parameters.toneCurve)),
                       "4700e2c82549d7c475119be74539f2d0594484422fb37afe6f789219b2f5e5d3")
        XCTAssertEqual(portrait.parameters.colorBands[0].hue, 11)
        XCTAssertEqual(portrait.parameters.colorBands[5].hue, -16)
        XCTAssertEqual(portrait.parameters.colorBands[5].brightness, 11)
        XCTAssertEqual(curveHash(try XCTUnwrap(portrait.parameters.toneCurve)),
                       "3e2a4eb44786f539f4ef14d0db034d98b15e902c25f7917b35586bfd232c881b")
    }

    func testNeutralProtectionRejectsNoiseAndPreservesEstablishedColor() {
        XCTAssertEqual(Np3FilterEngine.neutralProtectionWeight(0), 0)
        XCTAssertEqual(Np3FilterEngine.neutralProtectionWeight(Np3FilterEngine.neutralProtectionChromaStart), 0)
        XCTAssertEqual(Np3FilterEngine.neutralProtectionWeight(Np3FilterEngine.neutralProtectionChromaEnd), 1)
        XCTAssertEqual(Np3FilterEngine.neutralProtectionWeight(1), 1)
        let start = Np3FilterEngine.neutralProtectionChromaStart
        let end = Np3FilterEngine.neutralProtectionChromaEnd
        XCTAssertEqual(Np3FilterEngine.neutralProtectionWeight((start + end) / 2), 0.5, accuracy: 0.0001)
        let weights = (0...16).map { Np3FilterEngine.neutralProtectionWeight(start + (end - start) * Float($0) / 16) }
        XCTAssertTrue(zip(weights, weights.dropFirst()).allSatisfy { $0 <= $1 })
    }

    func testBoundedHueAndSecondaryComponentMatchAndroidModuloDefinition() {
        for hue: Float in [-60, -30, -0.01, 0, 30, 359.99, 360, 390] {
            let expected = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
            XCTAssertEqual(Np3FilterEngine.normalizeHue(hue), expected)
        }
        for step in 0...3_599 {
            let hue = Float(step) / 10
            let section = hue / 60
            let expected: Float = 0.73 * (1 - abs(section.truncatingRemainder(dividingBy: 2) - 1))
            XCTAssertEqual(Np3FilterEngine.hslSecondaryComponent(section: section, sector: Int(section), chroma: 0.73),
                           expected, accuracy: 0.000001)
        }
    }

    func testLookupPreservesAlphaAndTransparentSourcePixels() {
        XCTAssertEqual(Np3FilterEngine.exactLookupOutputColor(originalColor: 0x00112233, mappedRGB: 0x00123456, preserveAlpha: false), 0xff123456)
        XCTAssertEqual(Np3FilterEngine.exactLookupOutputColor(originalColor: 0x7f112233, mappedRGB: 0x00123456, preserveAlpha: true), 0x7f123456)
        XCTAssertEqual(Np3FilterEngine.exactLookupOutputColor(originalColor: 0x00112233, mappedRGB: 0x00123456, preserveAlpha: true), 0x00112233)
    }

    func testIntensityHasAndroidEvenDetentsAndSeparateDisabledState() {
        XCTAssertEqual(Np3FilterEngine.defaultIntensityPercent, 80)
        XCTAssertEqual([Int.min, 0, 1, 2, 3, 79, 80, 81, 99, 100, Int.max].map(Np3FilterEngine.normalizeIntensity),
                       [2, 2, 2, 2, 4, 80, 80, 82, 100, 100, 100])
    }

    func testCancellationStopsAtAndroidStripeCheckBoundary() throws {
        let preset = try XCTUnwrap(Np3FilterCatalog.presets.first)
        let engine = Np3FilterEngine(parameters: preset.parameters, intensityPercent: 80)
        let original: UInt32 = 0xff808080
        var pixels = [UInt32](repeating: original, count: 8_192)
        var checks = 0
        XCTAssertThrowsError(try engine.filterPixels(&pixels) {
            checks += 1
            return checks == 2
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(pixels.prefix(4_096).allSatisfy { $0 == engine.filterPixel(original) })
        XCTAssertTrue(pixels.suffix(4_096).allSatisfy { $0 == original })
        var untouched = [UInt32](repeating: original, count: 8)
        XCTAssertThrowsError(try engine.filterPixels(&untouched, isCancelled: { true }))
        XCTAssertEqual(untouched, [UInt32](repeating: original, count: 8))
    }

    private func curveHash(_ values: [UInt16]) -> String {
        let bytes = values.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xff)] }
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }
}
