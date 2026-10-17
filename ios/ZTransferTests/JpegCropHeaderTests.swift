import XCTest
import UIKit
@testable import ZTransfer

final class JpegCropHeaderTests: XCTestCase {
    private let header = Data([0xff,0xd8, 0xff,0xc0, 0,17, 8, 0x01,0x00, 0x02,0x00, 3,
                               1,0x22,0, 2,0x11,0, 3,0x11,0, 0xff,0xda,0,2])

    func testReadsSOFDimensionsAndSampling() {
        let source = parseJpegCropHeader(header)
        XCTAssertEqual(source?.width, 512); XCTAssertEqual(source?.height, 256)
        XCTAssertEqual(source?.mcuWidth, 16); XCTAssertEqual(source?.mcuHeight, 16)
    }

    func testRejectsEveryIncompletePrefixAndInvalidComponentSampling() {
        for count in 0..<header.count {
            XCTAssertNil(parseJpegCropHeader(header.prefix(count)), "prefix \(count)")
        }
        for component in 0..<3 {
            for invalid: UInt8 in [0x00, 0x01, 0x10, 0x51, 0x15] {
                var bytes = header
                bytes[13 + component * 3] = invalid
                XCTAssertNil(parseJpegCropHeader(bytes), "component \(component), sampling \(invalid)")
            }
        }
        for sampling: UInt8 in [0x11, 0x22, 0x44] {
            var bytes = header
            bytes[13] = sampling
            XCTAssertEqual(parseJpegCropHeader(bytes)?.mcuWidth, Int(sampling >> 4) * 8)
        }
    }

    func testRejectsBrokenExifAndTruncatedSegmentsInsteadOfUsingFrameGeometry() {
        // Valid little-endian orientation 6, matching Android CropSelectionTest.
        let exif: [UInt8] = [69,120,105,102,0,0,73,73,42,0,8,0,0,0,1,0,
                             0x12,1,3,0,1,0,0,0,6,0,0,0,0,0,0,0]
        func jpeg(_ payload: [UInt8]) -> Data {
            header.prefix(2) + segment(0xe1, payload: Data(payload)) + header.dropFirst(2)
        }
        XCTAssertEqual(parseJpegCropHeader(jpeg(exif))?.orientation, 6)
        for (index, value): (Int, UInt8) in [(6,0), (8,0), (10,0xff), (14,0xff), (18,4), (20,2), (24,9)] {
            var invalid = exif; invalid[index] = value
            XCTAssertNil(parseJpegCropHeader(jpeg(invalid)), "EXIF byte \(index)")
        }
        XCTAssertNil(parseJpegCropHeader(header.prefix(2) + Data([0xff,0xe2,0xff,0xff,1,2,3]) + header.dropFirst(2)))
    }

    func testProductionCropAcceptsLargeHeadersThroughExactReadLimitAndRejectsBeyondIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try jpegFixture()
        let source = try XCTUnwrap(parseJpegCropHeader(original))
        let task = LosslessCropTask(fileID: 1, recipe: .init(source: source, rect: .init(left: 16, top: 16, right: 80, bottom: 80)))
        let sos = try XCTUnwrap(original.range(of: Data([0xff,0xda]))).lowerBound
        let input = directory.appendingPathComponent("source.jpg")
        for requiredPrefix in [65540, LosslessCropInput.maximumHeaderBytes, LosslessCropInput.maximumHeaderBytes + 1] {
            let padding = commentPadding(count: requiredPrefix - 4 - sos)
            let bytes = original.prefix(2) + padding + original.dropFirst(2)
            try bytes.write(to: input)
            let bounded = try LosslessCropInput.sourceHeader(from: input)
            XCTAssertLessThanOrEqual(bounded.count, LosslessCropInput.maximumHeaderBytes)
            if requiredPrefix <= LosslessCropInput.maximumHeaderBytes {
                XCTAssertEqual(parseJpegCropHeader(bounded), source)
                let output = try LosslessCropProcessor.process(task: task, sourceURL: input, directory: directory)
                XCTAssertEqual(UIImage(contentsOfFile: output.path)?.cgImage?.width, 64)
                try FileManager.default.removeItem(at: output)
            } else {
                XCTAssertNil(parseJpegCropHeader(bounded))
                XCTAssertThrowsError(try LosslessCropProcessor.process(task: task, sourceURL: input, directory: directory, transform: { _, _, _, _ in
                    XCTFail("Incomplete bounded header entered native work")
                    return false
                }))
            }
            XCTAssertEqual(try Data(contentsOf: input), bytes)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["source.jpg"])
        }
    }

    func testLargeICCBeforeSOFSurvivesProductionCrop() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try jpegFixture()
        let source = try XCTUnwrap(parseJpegCropHeader(original))
        var profile = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData()) as Data
        profile.append(Data(repeating: 0, count: max(0, 80000 - profile.count)))
        for index in 0..<4 { profile[index] = UInt8(truncatingIfNeeded: profile.count >> ((3 - index) * 8)) }
        let signature = Data("ICC_PROFILE\0".utf8)
        let first = segment(0xe2, payload: signature + Data([1,2]) + profile.prefix(60000))
        let second = segment(0xe2, payload: signature + Data([2,2]) + profile.dropFirst(60000))
        let bytes = original.prefix(2) + first + second + original.dropFirst(2)
        let input = directory.appendingPathComponent("source.jpg")
        try bytes.write(to: input)
        XCTAssertNil(parseJpegCropHeader(bytes.prefix(65536)))
        let task = LosslessCropTask(fileID: 1, recipe: .init(source: source, rect: .init(left: 16, top: 16, right: 80, bottom: 80)))
        let output = try LosslessCropProcessor.process(task: task, sourceURL: input, directory: directory)
        let result = try Data(contentsOf: output)
        XCTAssertNotNil(result.range(of: first))
        XCTAssertNotNil(result.range(of: second))
        XCTAssertEqual(parseJpegCropHeader(result)?.width, 64)
        XCTAssertEqual(try Data(contentsOf: input), bytes)
    }

    private func jpegFixture() throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 96), format: format).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 128, height: 96))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.95))
    }

    private func segment(_ marker: UInt8, payload: Data) -> Data {
        let length = payload.count + 2
        return Data([0xff, marker, UInt8(length >> 8), UInt8(length & 255)]) + payload
    }

    private func commentPadding(count: Int) -> Data {
        var remaining = count, result = Data()
        while remaining > 0 {
            var size = min(65537, remaining)
            if (1...3).contains(remaining - size) { size -= 4 }
            precondition(size >= 4)
            result.append(segment(0xfe, payload: Data(repeating: 0x41, count: size - 4)))
            remaining -= size
        }
        return result
    }
}
