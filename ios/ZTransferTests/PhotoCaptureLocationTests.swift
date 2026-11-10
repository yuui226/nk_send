import XCTest
import UIKit
import ImageIO
@testable import ZTransfer

final class PhotoCaptureLocationTests: XCTestCase {
    func testLocationValidationAllowsAxesAndSeaLevelButRejectsPlaceholders() {
        for pair in [(0.0, 0.0), (91, 1), (-91, 1), (1, 181), (1, -181),
                     (Double.nan, 1), (1, .infinity)] {
            XCTAssertNil(PhotoCaptureLocation(latitude: pair.0, longitude: pair.1, altitude: 0))
        }
        XCTAssertNil(PhotoCaptureLocation(latitude: nil, longitude: 1, altitude: 0))
        for pair in [(0.0, 1.0), (1, 0), (-90, -180), (90, 180)] {
            XCTAssertEqual(PhotoCaptureLocation(latitude: pair.0, longitude: pair.1, altitude: 0)?.altitude, 0)
            XCTAssertNil(PhotoCaptureLocation(latitude: pair.0, longitude: pair.1, altitude: .nan)?.altitude)
        }
    }

    /// Android LosslessCropInstrumentation: real native coefficients + EXIF
    /// round-trip, both sync/async entry points, all display orientations.
    func testMissingGPSUsesSamePhotoSnapshotWithoutInventingTimeOrChangingOriginal() async throws {
        let root = try directory(), input = root.appendingPathComponent("source.jpg")
        for orientation in 1...8 {
            for location in [
                try XCTUnwrap(PhotoCaptureLocation(latitude: 48.8566, longitude: 2.3522, altitude: -7.25)),
                try XCTUnwrap(PhotoCaptureLocation(latitude: -33.868812345, longitude: 151.209312345, altitude: 0)),
                try XCTUnwrap(PhotoCaptureLocation(latitude: 0, longitude: -180, altitude: nil))
            ] {
                let original = try jpeg(orientation: orientation)
                try original.write(to: input)
                let task = try cropTask(original)
                let output = orientation.isMultiple(of: 2)
                    ? try await LosslessCropProcessor.processAsync(task: task, sourceURL: input, directory: root, locationFallback: location)
                    : try LosslessCropProcessor.process(task: task, sourceURL: input, directory: root, locationFallback: location)
                let result = try Data(contentsOf: output)
                let props = try properties(result), gps = try XCTUnwrap(props[kCGImagePropertyGPSDictionary] as? NSDictionary)
                // ImageIO normalizes some GPS DMS fractions to a shorter
                // display value. The raw TIFF rationals remain authoritative.
                let actualLatitude = try XCTUnwrap(gps[kCGImagePropertyGPSLatitude] as? NSNumber).doubleValue
                let actualLongitude = try XCTUnwrap(gps[kCGImagePropertyGPSLongitude] as? NSNumber).doubleValue
                let label = "orientation=\(orientation) location=\(location)"
                let raw = try rawGPSCoordinates(result)
                XCTAssertEqual(raw.0, abs(location.latitude), accuracy: 1e-8, label)
                XCTAssertEqual(raw.1, abs(location.longitude), accuracy: 1e-8, label)
                let decoded = try XCTUnwrap(PhotoCaptureLocation.read(header: result))
                XCTAssertEqual(decoded.latitude, location.latitude, accuracy: 1e-8, label)
                XCTAssertEqual(decoded.longitude, location.longitude, accuracy: 1e-8, label)
                XCTAssertEqual(actualLatitude, raw.0, accuracy: 1e-6, label)
                XCTAssertEqual(actualLongitude, raw.1, accuracy: 1e-6, label)
                XCTAssertEqual(gps[kCGImagePropertyGPSLatitudeRef] as? String, location.latitude < 0 ? "S" : "N")
                XCTAssertEqual(gps[kCGImagePropertyGPSLongitudeRef] as? String, location.longitude < 0 ? "W" : "E")
                if let altitude = location.altitude {
                    XCTAssertEqual(try XCTUnwrap(gps[kCGImagePropertyGPSAltitude] as? NSNumber).doubleValue, abs(altitude), accuracy: 1e-8)
                    XCTAssertEqual((gps[kCGImagePropertyGPSAltitudeRef] as? NSNumber)?.intValue, altitude < 0 ? 1 : 0)
                } else {
                    XCTAssertNil(gps[kCGImagePropertyGPSAltitude]); XCTAssertNil(gps[kCGImagePropertyGPSAltitudeRef])
                }
                XCTAssertNil(gps[kCGImagePropertyGPSDateStamp]); XCTAssertNil(gps[kCGImagePropertyGPSTimeStamp])
                XCTAssertEqual((props[kCGImagePropertyOrientation] as? NSNumber)?.intValue, orientation)
                XCTAssertEqual((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 64)
                XCTAssertEqual((props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 48)
                XCTAssertEqual(try Data(contentsOf: input), original)
                try FileManager.default.removeItem(at: output)
            }
        }
    }

    func testPartialInvalidGPSDiscardsStaleAltitudeOnlyWhenRecovering() throws {
        let root = try directory(), input = root.appendingPathComponent("source.jpg")
        for partial: [CFString: Any] in [
            [kCGImagePropertyGPSAltitude: 999, kCGImagePropertyGPSAltitudeRef: 1],
            [kCGImagePropertyGPSLatitude: 31, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSAltitude: 999, kCGImagePropertyGPSAltitudeRef: 0],
            [kCGImagePropertyGPSLatitude: 0, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 0, kCGImagePropertyGPSLongitudeRef: "E", kCGImagePropertyGPSAltitude: 999]
        ] {
            var partial = partial; partial[kCGImagePropertyGPSMapDatum] = "WGS-84"
            let original = try jpeg(gps: partial)
            XCTAssertNil(PhotoCaptureLocation.read(header: original))
            try original.write(to: input)
            let task = try cropTask(original)
            for altitude: Double? in [nil, -7.25, 0] {
                let output = try LosslessCropProcessor.process(task: task, sourceURL: input, directory: root,
                    locationFallback: PhotoCaptureLocation(latitude: 48.8566, longitude: 2.3522, altitude: altitude))
                let saved = try Data(contentsOf: output)
                let result = try XCTUnwrap(PhotoCaptureLocation.read(header: saved))
                XCTAssertEqual(result.altitude, altitude)
                let gps = try XCTUnwrap(try properties(saved)[kCGImagePropertyGPSDictionary] as? NSDictionary)
                XCTAssertEqual(gps[kCGImagePropertyGPSMapDatum] as? String, "WGS-84")
                XCTAssertEqual(try Data(contentsOf: input), original)
                try FileManager.default.removeItem(at: output)
            }
        }
    }

    func testNoFallbackDoesNotInventGPSAndFailedGPSValidationCleansStaging() async throws {
        let root = try directory(), input = root.appendingPathComponent("source.jpg")
        let original = try jpeg(); try original.write(to: input)
        let task = try cropTask(original)
        let plain = try LosslessCropProcessor.process(task: task, sourceURL: input, directory: root)
        XCTAssertNil(PhotoCaptureLocation.read(header: try Data(contentsOf: plain)))
        let plainGPS = try properties(Data(contentsOf: plain))[kCGImagePropertyGPSDictionary] as? NSDictionary
        XCTAssertNil(plainGPS?[kCGImagePropertyGPSLatitude]); XCTAssertNil(plainGPS?[kCGImagePropertyGPSLongitude])
        try FileManager.default.removeItem(at: plain)
        // Simulate a codec/metadata stage that reports success but drops GPS.
        // Publication must verify the saved JPEG and delete only its staging.
        let location = try XCTUnwrap(PhotoCaptureLocation(latitude: 1, longitude: 2, altitude: nil))
        do {
            _ = try await LosslessCropProcessor.processAsync(task: task, sourceURL: input, directory: root,
                locationFallback: location, transform: { source, output, geometry, rect in
                    LosslessJpegBridge.crop(input: source, output: output, source: geometry, rect: rect)
                })
            XCTFail("Missing promised GPS was published")
        } catch { XCTAssertEqual(error as? LosslessCropProcessorError, .cropFailed) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["source.jpg"])
        XCTAssertEqual(try Data(contentsOf: input), original)
        let retry = try await LosslessCropProcessor.processAsync(task: task, sourceURL: input, directory: root, locationFallback: location)
        XCTAssertNotNil(PhotoCaptureLocation.read(header: try Data(contentsOf: retry)))
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func cropTask(_ data: Data) throws -> LosslessCropTask {
        .init(fileID: 1, recipe: .init(source: try XCTUnwrap(parseJpegCropHeader(data)),
            rect: .init(left: 16, top: 16, right: 80, bottom: 64)))
    }
    private func properties(_ data: Data) throws -> NSDictionary {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?)
    }
    /// Independent minimal fixture reader, with checked offsets. It never uses
    /// the production parser or ImageIO to derive the expected precision.
    private func rawGPSCoordinates(_ jpeg: Data) throws -> (Double, Double) {
        let signature = try XCTUnwrap(jpeg.range(of: Data("Exif\0\0".utf8)))
        let tiff = Array(jpeg[signature.upperBound...])
        let little = tiff.prefix(2).elementsEqual([0x49, 0x49])
        func integer(_ offset: Int, _ size: Int) throws -> Int {
            guard offset >= 0, offset <= tiff.count - size else { throw CocoaError(.fileReadCorruptFile) }
            return (0..<size).reduce(0) { $0 | Int(tiff[offset + $1]) << ((little ? $1 : size - 1 - $1) * 8) }
        }
        func field(_ tag: Int, directory: Int) throws -> Int {
            let count = try integer(directory, 2)
            for i in 0..<count {
                let offset = directory + 2 + i * 12
                if try integer(offset, 2) == tag { return offset }
            }
            throw CocoaError(.fileReadCorruptFile)
        }
        let root = try integer(4, 4)
        let gps = try integer(field(0x8825, directory: root) + 8, 4)
        func coordinate(_ tag: Int) throws -> Double {
            let entry = try field(tag, directory: gps)
            XCTAssertEqual(try integer(entry + 2, 2), 5)
            XCTAssertEqual(try integer(entry + 4, 4), 3)
            let offset = try integer(entry + 8, 4)
            var value = 0.0
            for (i, scale) in [1.0, 60, 3600].enumerated() {
                let numerator = try integer(offset + 8 * i, 4), denominator = try integer(offset + 8 * i + 4, 4)
                guard denominator > 0 else { throw CocoaError(.fileReadCorruptFile) }
                value += Double(numerator) / Double(denominator) / scale
            }
            return value
        }
        return try (coordinate(2), coordinate(4))
    }
    private func jpeg(orientation: Int = 1, gps: [CFString: Any]? = nil) throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 96), format: format).image {
            UIColor.blue.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 128, height: 96))
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        if let gps { properties[kCGImagePropertyGPSDictionary] = gps }
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
