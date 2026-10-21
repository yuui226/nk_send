import XCTest
@testable import ZTransfer

final class NikonPictureControlTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let root = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
        return try Data(contentsOf: root.appendingPathComponent("PictureControlFixtures").appendingPathComponent(name))
    }
    private func reads() throws -> [(item: Int, data: Data)] {
        let text = String(decoding: try fixture("z30-v3.tsv"), as: UTF8.self)
        return text.split(separator: "\n").filter { !$0.hasPrefix("#") }.compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 5, fields[1] == "90CC", fields[3] == "2001" else { return nil }
            let bytes = Array(fields[4])
            let data = Data(stride(from: 0, to: bytes.count, by: 2).map {
                UInt8(String(bytes[$0...$0 + 1]), radix: 16)!
            })
            return (Int(fields[2].split(separator: ",")[0])!, data)
        }
    }

    func testAll74RealSuccessfulReadsPreserveEveryByteAndCustomBaseIdentity() throws {
        let captures = try reads()
        XCTAssertEqual(captures.count, 74)
        for capture in captures {
            let parsed = try NikonPictureControlData(item: capture.item, responseCode: 0x2001, data: capture.data)
            XCTAssertEqual(parsed.data, capture.data)
            if capture.item == 201 { XCTAssertEqual(parsed.baseItem, 111); XCTAssertEqual(parsed.name, "FUJI CC") }
            if (207...209).contains(capture.item) { XCTAssertTrue(parsed.isEmpty) }
            if let curve = parsed.curve { XCTAssertEqual(curve.samples.count, 257); XCTAssertEqual(curve.data.count, 578) }
        }
    }

    func testSixIndependentCameraExportsEncodeExactWireBytesWithManualSharpening() throws {
        let captures = try reads()
        for number in 1...6 {
            let file = try NikonPictureControlFile(fixture(String(format: "z30-exported/PICCON%02d.NP3", number)))
            var expected = try XCTUnwrap(captures.first { $0.item == 200 + number }?.data)
            expected[23] = 0
            XCTAssertEqual(try file.encodeClassicPictureControl(), expected, "Export \(number)")
            if number == 4 { XCTAssertEqual(file.name, "ADelicate portrait ") }
        }
    }

    func testUserNP3RoundTripAndEncodeWithoutDroppingCurveBytes() throws {
        for withCurve in [false, true] {
            let data = SyntheticPictureControlFixture.data(withCurve: withCurve)
            let file = try NikonPictureControlFile(data)
            XCTAssertEqual(file.data, data)
            XCTAssertEqual(file.name, "Test Neutral")
            XCTAssertEqual(file.sha256.count, 64)
            let encoded = try file.encodeClassicPictureControl()
            XCTAssertEqual(encoded.count, withCurve ? 614 : 36)
            if withCurve {
                let curve = try NikonPictureControlToneCurve(XCTUnwrap(file.field(2)))
                XCTAssertEqual(curve.samples, (0...256).map { $0 * 32767 / 256 })
                XCTAssertEqual(encoded.subdata(in: 36..<614), SyntheticPictureControlFixture.curve)
            } else { XCTAssertNil(file.field(2)) }
        }
    }

    func testFlexibleColorHasDistinctReasonOnlyForCompleteValidContainers() throws {
        for name in ["vanilla", "tonecurve-noop", "comment-a"] {
            let data = try fixture("flexible-color/\(name).NP3")
            XCTAssertThrowsError(try NikonPictureControlFile(data)) { error in
                XCTAssertEqual(error as? NikonPictureControlError, .flexibleColorUnsupported)
            }
            for length in 0..<data.count {
                XCTAssertThrowsError(try NikonPictureControlFile(Data(data.prefix(length)))) { error in
                    XCTAssertNotEqual(error as? NikonPictureControlError, .flexibleColorUnsupported)
                }
            }
            XCTAssertThrowsError(try NikonPictureControlFile(data + Data([0]))) { error in
                XCTAssertNotEqual(error as? NikonPictureControlError, .flexibleColorUnsupported)
            }
        }
    }

    func testTruncationAndNewVersionsCannotBecomeWritableOrEmptySlots() throws {
        let data = SyntheticPictureControlFixture.data()
        for length in 0..<data.count { XCTAssertThrowsError(try NikonPictureControlFile(Data(data.prefix(length)))) }
        for version in ["0301", "0310", "0399"] {
            var changed = data
            changed.replaceSubrange(12..<16, with: version.utf8)
            let file = try NikonPictureControlFile(changed)
            XCTAssertThrowsError(try file.encodeClassicPictureControl())
        }
        for length in [0, 35, 37, 613, 614, 615] {
            XCTAssertThrowsError(try NikonPictureControlData(item: 209, responseCode: 0x2001, data: Data(repeating: 0, count: length)))
        }
        XCTAssertThrowsError(try NikonPictureControlData(item: 209, responseCode: 0x2019, data: Data(repeating: 0, count: 36)))
        XCTAssertThrowsError(try NikonPictureControlData(item: 1, responseCode: 0x2001, data: Data(repeating: 0, count: 36)))
    }

    func testBoundedStreamAndCancellation() throws {
        let data = SyntheticPictureControlFixture.data()
        let input = InputStream(data: data); input.open(); defer { input.close() }
        XCTAssertEqual(try NikonPictureControlFile.read(input).data, data)
        let oversized = InputStream(data: Data(repeating: 0, count: 100_000)); oversized.open(); defer { oversized.close() }
        XCTAssertThrowsError(try NikonPictureControlFile.read(oversized))
        let cancelled = InputStream(data: data); cancelled.open(); defer { cancelled.close() }
        XCTAssertThrowsError(try NikonPictureControlFile.read(cancelled) { throw CancellationError() })
        XCTAssertEqual(try NikonPictureControlFile.read(cancelled).data, data)
    }

    func testCapabilityAutomaticAndUnavailableAdjustmentsAreRejected() throws {
        var dataset = Data(repeating: 0, count: 36)
        var capabilities = Data(repeating: 128, count: 28)
        try validatePictureControlCapabilities(dataset: dataset, capabilities: capabilities)
        dataset[25] = 128
        XCTAssertThrowsError(try validatePictureControlCapabilities(dataset: dataset, capabilities: capabilities))
        capabilities[2] = 129
        try validatePictureControlCapabilities(dataset: dataset, capabilities: capabilities)
        dataset[25] = 1; capabilities[2] = 0
        XCTAssertThrowsError(try validatePictureControlCapabilities(dataset: dataset, capabilities: capabilities))
        XCTAssertThrowsError(try validatePictureControlCapabilities(dataset: Data(), capabilities: capabilities))
    }
}
