import XCTest
@testable import ZTransfer

/// Original binary fixtures shared with Android PhotoNp3ParserTest and
/// ClassicPhotoNp3ParserTest. They belong to the test bundle only.
final class PhotoNp3ParserTests: XCTestCase {
    private func sample(_ name: String = "vanilla", group: String = "flexible-color") throws -> Data {
        let root = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
        return try Data(contentsOf: root.appendingPathComponent("PictureControlFixtures/\(group)/\(name).NP3"))
    }
    private func fields(_ data: Data) -> [UInt32: [UInt8]] {
        let bytes = Array(data); var cursor = 4, result: [UInt32: [UInt8]] = [:]
        func integer() -> UInt32 {
            defer { cursor += 4 }
            return bytes[cursor..<(cursor + 4)].reduce(0) { $0 << 8 | UInt32($1) }
        }
        while true {
            let tag = integer(); if tag == 0 { return result }
            let count = Int(integer()); result[tag] = Array(bytes[cursor..<(cursor + count)]); cursor += count
        }
    }
    private func encode(_ fields: [UInt32: [UInt8]], reversed: Bool = false) -> Data {
        var bytes: [UInt8] = [78, 67, 80, 0]
        func integer(_ value: UInt32) { for shift in [24, 16, 8, 0] { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) } }
        for tag in fields.keys.sorted(by: { reversed ? $0 > $1 : $0 < $1 }) {
            let value = fields[tag]!
            integer(tag); integer(UInt32(value.count)); bytes.append(contentsOf: value)
        }
        integer(0); return Data(bytes)
    }
    private func changed(_ name: String = "vanilla", _ change: (inout [UInt32: [UInt8]]) -> Void) throws -> Data {
        var values = fields(try sample(name)); change(&values); return encode(values)
    }
    private func flexible(_ data: Data) throws -> Np3FilterParameters {
        guard case let .flexible(value) = try PhotoNp3Parser.parse(data).recipe.parameters else {
            XCTFail("Expected Flexible Color"); throw CocoaError(.coderInvalidValue)
        }
        return value
    }
    private func classic(_ fields: [UInt32: [UInt8]]) throws -> ClassicNp3FilterParameters {
        guard case let .classic(value) = try PhotoNp3Parser.parse(encode(fields)).recipe.parameters else {
            XCTFail("Expected Classic"); throw CocoaError(.coderInvalidValue)
        }
        return value
    }
    private func color() throws -> [UInt32: [UInt8]] {
        var value = fields(try sample("PICCON04", group: "z30-exported")); value[2] = nil
        for tag in stride(from: UInt32(0x0800), through: 0x0b00, by: 0x100) { value[tag] = [128, 4] }
        return value
    }
    private func monochrome() throws -> [UInt32: [UInt8]] {
        var value = try color(); value[0x0300] = [6, 0x4d]
        for tag in [UInt32(0x0a00), 0x0b00] { value[tag] = [255, 4] }
        for tag in [UInt32(0x0c00), 0x0d00] { value[tag] = [128, 0] }
        return value
    }
    private func controls(_ p: Np3FilterParameters) -> [Int] { [p.contrast, p.highlights, p.shadows, p.whites, p.blacks, p.saturation] }
    private func failure(_ reason: PhotoNp3Failure, _ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try PhotoNp3Parser.parse(data), file: file, line: line) {
            XCTAssertEqual(($0 as? PhotoNp3Error)?.reason, reason, "\($0)", file: file, line: line)
        }
    }

    func testIndependentFlexibleSamplesPreserveIdentityCommentsAndCurve() throws {
        let parsed = try PhotoNp3Parser.parse(sample())
        XCTAssertEqual(parsed.sourceSha256, "1199d1e5ca7a1d0b39273e70be05d590ce1ee9fb6378f12e73aa91320d064483")
        XCTAssertEqual(parsed.recipe.preset.id, "np3:\(parsed.sourceSha256):np3-srgb-v1")
        XCTAssertEqual(parsed.recipe.preset.name, "vanilla"); XCTAssertTrue(parsed.ignoredDetailControls)
        let neutral = try flexible(sample())
        XCTAssertEqual(controls(neutral), [0, 0, 0, 0, 0, 0]); XCTAssertNil(neutral.toneCurve)
        XCTAssertTrue(neutral.colorBands.allSatisfy { $0.hue == 0 && $0.chroma == 0 && $0.brightness == 0 })
        XCTAssertEqual(try flexible(sample("comment-a")), neutral)
        let curved = try flexible(sample("tonecurve-noop"))
        XCTAssertEqual(controls(curved), [0, 0, 0, 0, 0, 0])
        XCTAssertEqual(curved.toneCurve?.count, 257)
        XCTAssertEqual(curved.toneCurve?.first, 0); XCTAssertEqual(curved.toneCurve?[128], 16_384); XCTAssertEqual(curved.toneCurve?.last, 32_767)
    }

    func testAllSixControlsAndEightBandsAreReadWithoutClamping() throws {
        let expected = [-27, 13, 100, -100, 8, 64]
        let bands = Np3FilterParameters.colorBandCenters.enumerated().map {
            Np3ColorBand(centerDegrees: $1, hue: $0 * 10 - 35, chroma: 100 - $0 * 20, brightness: $0 * 5 - 15)
        }
        let data = try changed { values in
            for (i, tag) in stride(from: UInt32(0x1900), through: 0x1e00, by: 0x100).enumerated() { values[tag]![0] = UInt8(128 + expected[i]) }
            for (i, band) in bands.enumerated() {
                for (j, v) in [band.hue, band.chroma, band.brightness].enumerated() { values[0x1f00]![i * 3 + j] = UInt8(128 + v) }
            }
        }
        let parsed = try flexible(data)
        XCTAssertEqual(controls(parsed), expected); XCTAssertEqual(parsed.colorBands, bands)
    }

    func testAllGradingRegionsAndMasksSurviveAndInactiveGradingCanonicalizes() throws {
        let expected = Np3ColorGrading(highlights: .init(hue: 360, chroma: 100, brightness: -100),
            midtones: .init(hue: 125, chroma: -33, brightness: 20), shadows: .init(hue: 256, chroma: -100, brightness: 75), blending: 0, balance: -100)
        let data = try changed { values in
            for (i, r) in [expected.highlights, expected.midtones, expected.shadows].enumerated() {
                values[0x2000]![i * 4] = UInt8(128 + (r.hue >> 8)); values[0x2000]![i * 4 + 1] = UInt8(r.hue & 255)
                values[0x2000]![i * 4 + 2] = UInt8(r.chroma + 128); values[0x2000]![i * 4 + 3] = UInt8(r.brightness + 128)
            }
            values[0x2000]![16] = 128; values[0x2000]![18] = 28
        }
        XCTAssertEqual(try flexible(data).colorGrading, expected)
        for offset in [2, 3, 6, 7, 10, 11] {
            XCTAssertFalse(try flexible(changed { $0[0x2000]![offset] = 129 }).colorGrading.isNeutral)
        }
        let neutral = try changed { $0[0x2000]![1] = 120; $0[0x2000]![16] = 208; $0[0x2000]![18] = 88 }
        XCTAssertEqual(try flexible(neutral), try flexible(sample()))
    }

    func testTLVOrderDoesNotChangeParametersAndSourceBytesCannotMutateRecipe() throws {
        var source = try sample("tonecurve-noop")
        let parsed = try PhotoNp3Parser.parse(source)
        var reordered = fields(source); reordered[0x10100] = [97, 0]
        let other = try PhotoNp3Parser.parse(encode(reordered, reversed: true))
        XCTAssertEqual(parsed.recipe.parameters, other.recipe.parameters)
        XCTAssertEqual(parsed.recipe.preset.name, other.recipe.preset.name)
        XCTAssertNotEqual(parsed.sourceSha256, other.sourceSha256)
        source.resetBytes(in: 0..<source.count)
        XCTAssertEqual(parsed, try PhotoNp3Parser.parse(sample("tonecurve-noop")))
    }

    func testEveryTruncationAndMalformedContainerIsInvalid() throws {
        let bytes = try sample("tonecurve-noop")
        for length in 0..<bytes.count { failure(.invalid, bytes.prefix(length)) }
        failure(.invalid, bytes + Data([0]))
        var bad = bytes; bad[0] = 0; failure(.invalid, bad)
        for high: UInt8 in [0x7f, 0xff] { var bad = bytes; bad[8] = high; failure(.invalid, bad) }
        failure(.invalid, bytes.dropLast(4) + bytes[4..<16] + Data(count: 4))
        failure(.invalid, Data([78, 67, 80, 0, 0, 0, 1, 0, 0]))
    }

    func testAllRequiredFieldsRejectMissingAndWrongLength() throws {
        for tag in fields(try sample()).keys {
            failure(.invalid, try changed { $0[tag] = nil })
            failure(.invalid, try changed { $0[tag] = Array($0[tag]!.dropLast()) })
        }
        for comment: [UInt8] in [[], [1, 2, 3], [1, 2], [1, 0, 2, 0]] {
            failure(.invalid, try changed { $0[0x10100] = comment })
        }
    }

    func testUnknownVersionsFieldsAndEncodingsRemainUnsupported() throws {
        for version in ["0300", "0301", "0399", "0100"] { failure(.unsupported, try changed { $0[0x0100] = Array(version.utf8) }) }
        failure(.unsupported, try changed { $0[0x2100] = [128, 1] })
        failure(.unsupported, try changed { $0[0x0300] = [0x7f, 0x7f] })
        for (tag, offset, value): (UInt32, Int, UInt8) in [(0x1900, 1, 4), (0x0800, 0, 128), (0x1400, 1, 4), (0x1f00, 24, 2), (0x2000, 12, 2), (0x2000, 0, 130)] {
            failure(.unsupported, try changed { $0[tag]![offset] = value })
        }
        failure(.invalid, try changed { $0[0x0100] = Array("03a0".utf8) })
    }

    func testOutOfRangeColorDetailAndGradingValuesAreNotClamped() throws {
        for value in [-101, 101] {
            for tag in stride(from: UInt32(0x1900), through: 0x1e00, by: 0x100) { failure(.invalid, try changed { $0[tag]![0] = UInt8(value + 128) }) }
            for offset in 0..<24 { failure(.invalid, try changed { $0[0x1f00]![offset] = UInt8(value + 128) }) }
            for offset in [2, 3, 6, 7, 10, 11, 18] { failure(.invalid, try changed { $0[0x2000]![offset] = UInt8(value + 128) }) }
        }
        for (tag, value): (UInt32, Int) in [(0x0600, 37), (0x0700, -21), (0x1600, 21), (0x1400, -3), (0x1400, 3)] {
            failure(.invalid, try changed { $0[tag]![0] = UInt8(value + 128) })
        }
        for value in [-1, 101] { failure(.invalid, try changed { $0[0x2000]![16] = UInt8(value + 128) }) }
        failure(.invalid, try changed { $0[0x2000]![0] = 129; $0[0x2000]![1] = 127 })
    }

    func testQuickAndDetailControlsAreValidatedWithoutSecondSharpeningPass() throws {
        var values = fields(try sample())
        for tag in [UInt32(0x0600), 0x0700, 0x1600] { values[tag]![0] = 128 }
        let expected = try flexible(encode(values))
        for raw: UInt8 in [0, 126, 127, 128, 129, 130, 255] {
            values[0x1400]![0] = raw
            let parsed = try PhotoNp3Parser.parse(encode(values))
            XCTAssertEqual(parsed.recipe.parameters, .flexible(expected))
            XCTAssertEqual(parsed.ignoredDetailControls, raw != 128 && raw != 255)
        }
    }

    func testCurveEditingMetadataIsNotDoubleAppliedAndReservedLayoutIsRejected() throws {
        let expected = try flexible(sample("tonecurve-noop"))
        let edited = try changed("tonecurve-noop") { $0[2]!.replaceSubrange(2..<8, with: [12, 255, 5, 245, 1, 7]) }
        XCTAssertEqual(try flexible(edited), expected)
        for (offset, value): (Int, UInt8) in [(8, 21), (64, 128)] {
            failure(.invalid, try changed("tonecurve-noop") { $0[2]![offset] = value })
        }
        failure(.invalid, try changed("tonecurve-noop") { $0[2]!.removeLast() })
        failure(.unsupported, try changed("tonecurve-noop") { $0[2]![1] = 49 })
        failure(.unsupported, try changed("tonecurve-noop") { $0[2]![63] = 1 })
        failure(.invalid, try changed { $0[0x1900]![0] = 1 })
        failure(.invalid, try changed("tonecurve-noop") { $0[0x1900]![0] = 255 })
    }

    func testNamesPreserveASCIIAndRejectMalformedOrUnsupportedEncoding() throws {
        for bytes: [UInt8] in [Array(repeating: 65, count: 20), [0] + Array(repeating: 65, count: 19), Array(repeating: 32, count: 19) + [0], [65, 0, 1] + Array(repeating: 0, count: 17)] {
            failure(.invalid, try changed { $0[0x0200] = bytes })
        }
        for first: UInt8 in [1, 0x80, 0xff] {
            failure(.unsupported, try changed { $0[0x0200] = [first] + Array(repeating: 0, count: 19) })
        }
    }

    func testBoundedReaderAcceptsShortChunksAndStopsAtOneOverflowByte() throws {
        let source = try sample(); var offset = 0
        let parsed = try PhotoNp3Parser.read { count in
            guard offset < source.count else { return nil }
            let end = min(source.count, offset + min(count, 7)); defer { offset = end }
            return source.subdata(in: offset..<end)
        }
        XCTAssertEqual(parsed, try PhotoNp3Parser.parse(source))
        failure(.tooLarge, Data(count: PhotoNp3Parser.maximumBytes + 1))
        var consumed = 0
        XCTAssertThrowsError(try PhotoNp3Parser.read { count in consumed += count; return Data(count: count) }) {
            XCTAssertEqual(($0 as? PhotoNp3Error)?.reason, .tooLarge)
        }
        XCTAssertEqual(consumed, PhotoNp3Parser.maximumBytes + 1)
    }

    func testReaderCancellationStallAndProviderFailureRemainDistinct() throws {
        var consumed = 0
        XCTAssertThrowsError(try PhotoNp3Parser.read(chunk: { _ in consumed += 1; return nil }, checkpoint: { throw CancellationError() })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(consumed, 0)
        XCTAssertThrowsError(try PhotoNp3Parser.read { _ in Data() }) { XCTAssertEqual(($0 as? PhotoNp3Error)?.reason, .invalid) }
        XCTAssertThrowsError(try PhotoNp3Parser.read { _ in throw CocoaError(.fileReadNoPermission) }) {
            XCTAssertEqual(($0 as? CocoaError)?.code, .fileReadNoPermission)
        }
        var checkpoints = 0
        XCTAssertThrowsError(try PhotoNp3Parser.read(chunk: { _ in nil }, checkpoint: {
            checkpoints += 1; if checkpoints == 2 { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checkpoints, 2)
    }

    func testRealFileHandleUsesTheSameReadLimitAndDoesNotRetainSource() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("np3-read-\(UUID()).NP3")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try sample("tonecurve-noop")
        try source.write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        let parsed = try PhotoNp3Parser.read(from: handle)
        XCTAssertEqual(try handle.offset(), UInt64(source.count))
        try handle.close()
        try Data(count: PhotoNp3Parser.maximumBytes * 2).write(to: url)
        XCTAssertEqual(parsed, try PhotoNp3Parser.parse(source))
        let oversized = try FileHandle(forReadingFrom: url)
        defer { try? oversized.close() }
        XCTAssertThrowsError(try PhotoNp3Parser.read(from: oversized)) {
            XCTAssertEqual(($0 as? PhotoNp3Error)?.reason, .tooLarge)
        }
        XCTAssertEqual(try oversized.offset(), UInt64(PhotoNp3Parser.maximumBytes + 1))
    }

    func testSixPairedClassicCameraExportsRetainEveryCurveSampleAndSourceName() throws {
        for number in 1...6 {
            let source = try sample(String(format: "PICCON%02d", number), group: "z30-exported")
            let values = fields(source), parsed = try PhotoNp3Parser.parse(source)
            let actual = try classic(values)
            XCTAssertTrue(actual.isValid); XCTAssertTrue(parsed.ignoredDetailControls)
            XCTAssertEqual(parsed.recipe.preset.id, "np3:\(parsed.sourceSha256):np3-classic-srgb-v1")
            XCTAssertEqual(parsed.recipe.preset.name, String(decoding: values[0x0200]!.prefix(while: { $0 != 0 }), as: UTF8.self))
            if let curve = values[2] {
                let expected = stride(from: 64, to: 578, by: 2).map { UInt16(curve[$0]) << 8 | UInt16(curve[$0 + 1]) }
                XCTAssertEqual(actual.toneCurve, expected); XCTAssertEqual(actual.contrastQuarter, 0); XCTAssertEqual(actual.brightnessQuarter, 0)
            } else { XCTAssertNil(actual.toneCurve) }
        }
    }

    func testClassicQuarterStepsAndAutoRetainTheirExactMeaning() throws {
        var values = try color()
        values[0x0800] = [0, 4]; values[0x0900] = [122, 4]; values[0x0a00] = [129, 4]; values[0x0b00] = [139, 4]
        let actual = try classic(values)
        XCTAssertEqual([actual.contrastQuarter, actual.brightnessQuarter, actual.saturationQuarter, actual.hueQuarter], [-128, -6, 1, 11])
        values[0x0a00] = [0, 4]; XCTAssertEqual(try classic(values).saturationQuarter, -128)
        values[0x0300] = [2, 0xcf]
        for tag in [UInt32(0x0600), 0x0700, 0x0800, 0x0900, 0x0a00, 0x0b00, 0x1600] { values[tag] = [255, 4] }
        for tag in stride(from: UInt32(0x0f00), through: 0x1300, by: 0x100) { values[tag] = [128, 1] }
        XCTAssertEqual(try classic(values).base, .auto)
        XCTAssertEqual(try classic(values).contrastQuarter, 0)
        values[0x1000] = [129, 1]; failure(.unsupported, encode(values))
    }

    func testClassicMonochromeAndFixedCreativeTonesKeepIndependentDensity() throws {
        var values = try monochrome()
        values[0x0c00] = [132, 0]; values[0x0d00] = [137, 0]; values[0x0e00] = [155, 4]
        let mono = try classic(values)
        XCTAssertEqual(mono.base, .monochrome)
        XCTAssertEqual([mono.filterEffect, mono.toningEffect, mono.toningDensityQuarter, mono.saturationQuarter, mono.hueQuarter], [4, 9, 27, 0, 0])
        values[0x0300] = [8, 15]; values[0x0900] = [255, 4]; values[0x0d00] = [255, 0]
        values[0x0e00] = [156, 4]; values[0x1500] = [130, 10]
        let red = try classic(values)
        XCTAssertEqual(red.base, .red); XCTAssertEqual(red.toningEffect, 0)
        XCTAssertEqual(red.toningDensityQuarter, 28); XCTAssertEqual(red.effectLevel, 20)
        values[0x0d00] = [129, 0]; failure(.unsupported, encode(values))
    }

    func testEveryKnownClassicStyleAnd0310ContainerIsRoutedByBase() throws {
        XCTAssertEqual(ClassicNp3Style.allCases.count, 31)
        for base in ClassicNp3Style.allCases {
            var values = try base.isMonochrome ? monochrome() : color()
            values[0x0300] = [UInt8(base.rawValue >> 8), UInt8(base.rawValue & 255)]
            values[0x1500] = [base.isCreative ? 138 : 255, 10]
            XCTAssertEqual(try classic(values).base, base)
            XCTAssertEqual(try classic(values).effectLevel, 100)
        }
        var values = fields(try sample()); values[0x0300] = [4, 0x93]
        XCTAssertEqual(try classic(values).base, .richTonePortrait)
        values[0x1900] = [129, 1]; failure(.unsupported, encode(values))
        values[0x1900] = [128, 1]; values[0x1f00]![0] = 129; failure(.unsupported, encode(values))
        values[0x1f00]![0] = 128; values[0x2000]![2] = 129; failure(.unsupported, encode(values))
    }

    func testClassicInvalidAndUnsupportedControlsAreNotSilentlyDropped() throws {
        for (tag, bytes, reason): (UInt32, [UInt8]?, PhotoNp3Failure) in [
            (0x0600, nil, .invalid), (0x0800, [141, 4], .invalid), (0x0800, [1, 4], .invalid),
            (0x0900, [0, 4], .invalid), (0x0800, [128, 7], .unsupported),
            (0x0300, [0x7f, 0xff], .unsupported), (0x2100, [128, 1], .unsupported), (0x0c00, [131, 0], .unsupported)
        ] { var values = try color(); values[tag] = bytes; failure(reason, encode(values)) }
        for (tag, bytes): (UInt32, [UInt8]) in [(0x0c00, [133, 0]), (0x0e00, [157, 4])] {
            var values = try monochrome(); values[tag] = bytes; failure(.invalid, encode(values))
        }
        var values = fields(try sample("PICCON04", group: "z30-exported"))
        let baseline = try classic(values)
        values[2]!.replaceSubrange(2..<8, with: [12, 255, 5, 245, 1, 7]); values[2]![63] = 99
        XCTAssertEqual(try classic(values), baseline, "Classic editor metadata is already baked into the samples")
        values[2]![64] = 128; failure(.invalid, encode(values))
    }

    func testLegacyParameterDecodingDefaultsGradingAndRejectsUnsafeShapes() throws {
        let original = try flexible(sample())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["colorGrading"] = nil
        XCTAssertEqual(try JSONDecoder().decode(Np3FilterParameters.self, from: JSONSerialization.data(withJSONObject: object)), original)
        object["colorBands"] = []
        XCTAssertThrowsError(try JSONDecoder().decode(Np3FilterParameters.self, from: JSONSerialization.data(withJSONObject: object)))
        object["colorBands"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original.colorBands))
        object["colorGrading"] = ["highlights": ["hue": 361, "chroma": 0, "brightness": 0], "midtones": ["hue": 0, "chroma": 0, "brightness": 0], "shadows": ["hue": 0, "chroma": 0, "brightness": 0], "blending": 50, "balance": 0]
        XCTAssertThrowsError(try JSONDecoder().decode(Np3FilterParameters.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}
