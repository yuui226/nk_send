import XCTest
#if SWIFT_PACKAGE
@testable import ZTransferProtocol
#else
@testable import ZTransfer
#endif

final class NEFExifParityTests: XCTestCase {
    private struct Entry {
        let tag: Int
        let type: Int
        let values: [Int]
        init(_ tag: Int, _ values: [Int], type: Int = 4) {
            self.tag = tag; self.values = values; self.type = type
        }
    }
    private func fixture(little: Bool = true, compression: Int? = 7,
                         bits: [Int] = [8, 8, 8], offsets: [Int] = [1600, 1800],
                         primarySize: [Int] = [6000, 4000], thumbSize: [Int] = [160, 120],
                         subIFD: Bool = false, malformedJPEG: Bool = false, extra: [Entry] = []) -> Data {
        var data = Data(repeating: 0, count: 4096)
        func put(_ at: Int, _ value: Int, _ size: Int) {
            for i in 0..<size { data[at + i] = UInt8(truncatingIfNeeded: value >> ((little ? i : size - i - 1) * 8)) }
        }
        data[0] = little ? 73 : 77; data[1] = data[0]
        put(2, 42, 2); put(4, 8, 4)
        var external = 600
        func directory(_ offset: Int, _ entries: [Entry], next: Int = 0) {
            put(offset, entries.count, 2)
            for (index, entry) in entries.enumerated() {
                let at = offset + 2 + index * 12
                let unit = entry.type == 3 ? 2 : 4
                put(at, entry.tag, 2); put(at + 2, entry.type, 2); put(at + 4, entry.values.count, 4)
                let start = entry.values.count * unit > 4 ? external : at + 8
                if start == external { put(at + 8, external, 4); external += entry.values.count * unit }
                for (i, value) in entry.values.enumerated() { put(start + i * unit, value, unit) }
            }
            put(offset + 2 + entries.count * 12, next, 4)
        }
        var primary: [Entry] = primarySize.isEmpty ? [.init(274, [1], type: 3)] : [.init(256, [primarySize[0]]), .init(257, [primarySize[1]])]
        if subIFD { primary.append(.init(330, [128])) }
        directory(8, primary, next: subIFD ? 0 : 128)
        var thumbnail: [Entry] = thumbSize.isEmpty ? [] : [.init(256, [thumbSize[0]]), .init(257, [thumbSize[1]])]
        if let compression { thumbnail.append(.init(259, [compression], type: 3)) }
        if compression == 6 || compression == nil {
            let jpeg = malformedJPEG ? Data([255, 216, 1, 2, 3, 255, 217]) : Self.sofJPEG
            thumbnail += [.init(513, [1600]), .init(514, [jpeg.count])]
            data.replaceSubrange(1600..<(1600 + jpeg.count), with: jpeg)
        } else {
            thumbnail += [.init(258, bits, type: 3), .init(273, offsets), .init(279, [4, 3])]
            data.replaceSubrange(1600..<1604, with: [255, 216, 1, 2])
            data.replaceSubrange(1800..<1803, with: [3, 255, 217])
        }
        directory(128, thumbnail + extra)
        return data
    }
    private static let sofJPEG = Data([255, 216, 255, 192, 0, 11, 8, 0, 120, 0, 160, 1, 1, 17, 0, 255, 217])
    private var cases: [(String, Data, Data?)] {
        let joined = Data([255, 216, 1, 2, 3, 255, 217])
        return [
            ("little-strips", fixture(), joined),
            ("big-strips", fixture(little: false), joined),
            ("uncompressed-strips", fixture(compression: 1), joined),
            ("jfif", fixture(compression: 6), Self.sofJPEG),
            ("big-jfif", fixture(little: false, compression: 6), Self.sofJPEG),
            ("implicit-jfif", fixture(compression: nil), Self.sofJPEG),
            ("invalid-jfif", fixture(compression: 6, malformedJPEG: true), nil),
            ("invalid-implicit-jfif", fixture(compression: nil, malformedJPEG: true), nil),
            ("unsupported-compression", fixture(compression: 8), nil),
            ("unsupported-bits", fixture(bits: [12, 12, 12]), nil),
            ("reversed-strips", fixture(offsets: [1800, 1600]), Data()),
            ("overlapping-strips", fixture(offsets: [1600, 1602]), Data()),
            ("short-strip", Data(fixture().prefix(1802)), Data()),
            ("short-directory", Data(fixture().prefix(150)), nil),
            ("missing-primary-size", fixture(primarySize: []), joined),
            ("ifd1-dimensions-not-swapped", fixture(primarySize: [80, 60]), joined),
            ("no-swap-one-dimension", fixture(primarySize: [80, 6000]), joined),
            ("small-subifd-promoted", fixture(subIFD: true), joined),
            ("large-subifd-not-promoted", fixture(thumbSize: [640, 480], subIFD: true), nil),
            ("large-nextifd-still-read", fixture(thumbSize: [640, 480]), joined),
            ("unknown-tag-skipped", fixture(extra: [.init(0xDEAD, [1, 2])]), joined),
            ("unsupported-strip-format", fixture(extra: [.init(273, [1600, 1800], type: 1)]), joined)
        ]
    }
    func testExif137ThumbnailSelectionAndBytes() {
        for (name, input, expected) in cases {
            XCTAssertEqual(NEFExifThumbnail.read(input), expected, name)
        }
    }

    /// Optional differential run against the *unmodified* 1.3.7 classes.jar.
    /// Host stubs provide only Log, Pair and Build; all parsing is AndroidX.
    func testAgainstActualAndroidX137() throws {
        #if os(macOS)
        let env = ProcessInfo.processInfo.environment
        guard let java = env["NEF_EXIF_JAVA"], let classpath = env["NEF_EXIF_ORACLE_CLASSPATH"] else {
            throw XCTSkip("Set NEF_EXIF_JAVA and NEF_EXIF_ORACLE_CLASSPATH for AndroidX differential test")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtures = cases
        let paths = try fixtures.map { name, input, _ in
            let url = directory.appendingPathComponent(name + ".nef")
            try input.write(to: url)
            return url.path
        }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: java)
        process.arguments = ["-cp", classpath, "Oracle"] + paths
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let rows = String(decoding: output, as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(rows.count, fixtures.count)
        for (row, fixture) in zip(rows, fixtures) {
            let fields = row.split(separator: "\t", omittingEmptySubsequences: false)
            XCTAssertEqual(String(fields[0]), fixture.0 + ".nef")
            let android = fields[1] == "null" ? nil : Data(base64Encoded: String(fields[1]))
            XCTAssertEqual(NEFExifThumbnail.read(fixture.1), android, fixture.0)
        }
        #else
        throw XCTSkip("AndroidX oracle runs on the macOS host")
        #endif
    }
}
