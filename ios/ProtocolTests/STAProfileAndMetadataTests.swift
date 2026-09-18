import XCTest
import ImageIO
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
@testable import ZTransferProtocol
#else
@testable import ZTransfer
#endif

final class STAProfileTests: XCTestCase {
    func testIdentityPersistsAcrossInstancesAndBothIdentitiesStayIndependent() {
        let fixture = STAProfileFixture(), store = fixture.store
        let paired = store.initiatorID(.pairedComputer), album = store.initiatorID(.albumExplorer)
        XCTAssertEqual(paired.count, 16); XCTAssertEqual(album.count, 16); XCTAssertNotEqual(paired, album)
        XCTAssertTrue(paired.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
        let restored = STAProfileStore(preferences: fixture.connection, pairing: fixture.pairing)
        XCTAssertEqual(paired, restored.initiatorID(.pairedComputer))
        XCTAssertEqual(album, restored.initiatorID(.albumExplorer))
    }
    func testOnlyProtocolMarkerConfirmsPairingNotRouteOrLegacyField() {
        let fixture = STAProfileFixture(), guid = String(repeating: "a", count: 32)
        fixture.store.remember(guid: guid, ip: "10.0.0.2", identity: .albumExplorer)
        fixture.connection.set(true, forKey: "sta_camera_profile_v1.\(guid).paired")
        XCTAssertEqual(fixture.store.pairedCameraCount, 0)
        XCTAssertEqual(fixture.store.preferredIdentity(for: "10.0.0.2"), .pairedComputer)
        XCTAssertNil(fixture.store.mostRecentGUID)
        fixture.store.markPaired(guid)
        XCTAssertEqual(fixture.store.pairedCameraCount, 1)
        XCTAssertEqual(fixture.store.preferredIdentity(for: "10.0.0.2"), .albumExplorer)
        XCTAssertEqual(fixture.store.mostRecentGUID, guid)
    }
    func testResetClearsAllCamerasAndRotatesIdentityWhileRetainingMode() {
        let fixture = STAProfileFixture(), store = fixture.store
        let previous = store.initiatorID(.pairedComputer)
        _ = store.initiatorID(.albumExplorer)
        fixture.connection.set("STA", forKey: "wireless_mode")
        for value in ["1", "2"] {
            let guid = String(repeating: value, count: 32)
            store.markPaired(guid); store.remember(guid: guid, ip: "10.0.0.\(value)", identity: .pairedComputer)
        }
        store.resetPairing()
        XCTAssertEqual(store.pairedCameraCount, 0); XCTAssertNil(store.lastUsedIP); XCTAssertFalse(store.hasReusableProfile)
        XCTAssertEqual(fixture.connection.string(forKey: "wireless_mode"), "STA")
        XCTAssertNotEqual(store.initiatorID(.pairedComputer), previous)
    }
    func testMultipleLegacyBodiesNeverReceiveGuessedIP() {
        let fixture = STAProfileFixture()
        fixture.connection.removeObject(forKey: "sta_camera_profile_migration_v1")
        fixture.connection.set("10.0.0.8", forKey: "last_sta_camera_ip")
        fixture.connection.set("ALBUM_EXPLORER", forKey: "sta_last_initiator_identity")
        for value in ["1", "2"] { fixture.pairing.set(true, forKey: "sta_paired_" + String(repeating: value, count: 32)) }
        let migrated = STAProfileStore(preferences: fixture.connection, pairing: fixture.pairing)
        XCTAssertEqual(migrated.pairedCameraCount, 2)
        XCTAssertTrue(migrated.profiles.allSatisfy { $0.lastIP == nil && $0.identity == .pairedComputer })
        XCTAssertNil(migrated.mostRecentGUID)
    }
    func testSingleLegacyBodyKeepsItsRouteAndIdentity() {
        let fixture = STAProfileFixture(), guid = String(repeating: "1", count: 32)
        fixture.connection.removeObject(forKey: "sta_camera_profile_migration_v1")
        fixture.connection.set("10.0.0.8", forKey: "last_sta_camera_ip")
        fixture.connection.set("ALBUM_EXPLORER", forKey: "sta_last_initiator_identity")
        fixture.pairing.set(true, forKey: "sta_paired_" + guid)
        let migrated = STAProfileStore(preferences: fixture.connection, pairing: fixture.pairing)
        XCTAssertEqual(migrated.mostRecentGUID, guid)
        XCTAssertEqual(migrated.profiles.first?.lastIP, "10.0.0.8")
        XCTAssertEqual(migrated.preferredIdentity(for: "10.0.0.8"), .albumExplorer)
    }
}

@MainActor
final class STAMetadataTests: XCTestCase {
    func testMediaTypesAndDatesUseAndroidFallbackRules() {
        XCTAssertEqual(STAMediaMetadata.detectedExtension(Data([255, 216])), ".jpg")
        XCTAssertEqual(STAMediaMetadata.detectedExtension(Data([73, 73, 42, 0])), ".nef")
        XCTAssertEqual(STAMediaMetadata.detectedExtension(Data([0, 0, 0, 0]) + Data("ftypqt  ".utf8)), ".mov")
        XCTAssertEqual(STAMediaMetadata.detectedExtension(Data([1, 2, 3, 4])), ".bin")
        XCTAssertNil(STAMediaMetadata.extensionFromHandle(0x701961F5))
        XCTAssertEqual(STAMediaMetadata.captureDate("2026:08:24 13:57:15"), "20260824T135715")
        XCTAssertNil(STAMediaMetadata.captureDate("2026:08"))
        let anchor = STAMediaMetadata.Anchor(sequence: 0x1961F5, file: .init(directory: 101, number: 8693))
        XCTAssertEqual(STAMediaMetadata.derive(anchor, handle: 0x611961F4), .init(directory: 101, number: 8692))
        XCTAssertEqual(STAMediaMetadata.defaultFileName(.init(directory: 101, number: 8692), extension: ".mp4"), "DSC_8692.MP4")
        let rollover = STAMediaMetadata.Anchor(sequence: 100, file: .init(directory: 101, number: 0))
        XCTAssertEqual(STAMediaMetadata.derive(rollover, handle: 99), .init(directory: 100, number: 9999))
    }
    func testBulkMetadataExactLayoutAndNameSafety() {
        let payload = metadataDate(handle: 0x611961F4)
        XCTAssertEqual(STAMediaMetadata.indexedDates(payload), [0x611961F4: "20260824T135715"])
        XCTAssertTrue(STAMediaMetadata.indexedDates(Data(payload.dropLast())).isEmpty)
        XCTAssertTrue(STAMediaMetadata.indexedDates(payload + Data([0])).isEmpty)
        let names = staInteger(UInt32(1)) + staInteger(UInt32(7)) + staInteger(UInt16(0xDC07)) + staInteger(UInt16(0xFFFF)) + staString("DCIM\\101NZ_30\\DSC_8693.JPG")
        XCTAssertEqual(STAMediaMetadata.fileNamePropertyList(names), [7: "DSC_8693.JPG"])
        XCTAssertTrue(STAMediaMetadata.fileNamePropertyList(Data(names.dropLast())).isEmpty)
        XCTAssertNil(STAMediaMetadata.cameraBaseFileName("bad:name.JPG"))
        XCTAssertNil(STAMediaMetadata.cameraBaseFileName("bad\u{01}name.JPG"))
    }
    func testNefDateAndExactPreviewRangeFromAndroidFixture() {
        var bytes = Data(repeating: 0, count: 120)
        bytes.replaceSubrange(0..<2, with: [73, 73]); put(&bytes, 2, UInt16(42)); put(&bytes, 4, UInt32(8)); put(&bytes, 8, UInt16(2))
        put(&bytes, 10, UInt16(0x0132)); put(&bytes, 12, UInt16(2)); put(&bytes, 14, UInt32(20)); put(&bytes, 18, UInt32(40))
        bytes.replaceSubrange(40..<60, with: Data("2026:08:18 00:00:16\0".utf8))
        put(&bytes, 22, UInt16(0x014A)); put(&bytes, 24, UInt16(4)); put(&bytes, 26, UInt32(1)); put(&bytes, 30, UInt32(80))
        put(&bytes, 80, UInt16(2)); put(&bytes, 82, UInt16(0x0201)); put(&bytes, 84, UInt16(4)); put(&bytes, 86, UInt32(1)); put(&bytes, 90, UInt32(300000))
        put(&bytes, 94, UInt16(0x0202)); put(&bytes, 96, UInt16(4)); put(&bytes, 98, UInt32(1)); put(&bytes, 102, UInt32(1068298))
        let header = STAMediaMetadata.tiffHeader(bytes)
        XCTAssertEqual(header.captureDate, "20260818T000016")
        XCTAssertEqual(header.previews, [.init(offset: 300000, length: 1068298)])
    }
    func testNefJoinsAndroidExifInterfaceJPEGCompressedThumbnailStrips() {
        let bytes = nefStripThumbnailFixture()
        let metadata = STAMediaMetadata.tiffHeader(bytes)
        XCTAssertTrue(metadata.previews.isEmpty)
        XCTAssertEqual(STAMediaMetadata.nefExifThumbnail(bytes), Data([0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]))
        XCTAssertEqual(STAMediaMetadata.nefExifThumbnail(Data(bytes.prefix(178))), Data())
    }
    func testDirectNefHeaderUsesMarkerScanBeforeExifStripsLikeAndroid() async throws {
        let handle: UInt32 = 0x09000071
        let bytes = nefStripThumbnailFixture()
        let wire = STAScriptTransport([
            .init(0x9421, [handle], payload: staInteger(UInt64(24_000_000))),
            .init(0x9431, [handle, 0, 0, 128 * 1024, 0], payload: bytes),
        ])
        let reader = STAObjectReader(
            session: PTPSession(transport: wire),
            operations: [PTPConstants.getPartialObjectEx]
        )

        let file = try await reader.file(handle: handle, storage: 0x10001)
        let thumbnail = try await reader.thumbnail(handle: handle)

        XCTAssertEqual(file.fileExtension, ".nef")
        XCTAssertEqual(thumbnail, bytes.subdata(in: 152..<179))
        let commands = await wire.commands
        XCTAssertEqual(commands.map(\.code), [0x9421, 0x9431])
        let remaining = await wire.remaining; XCTAssertEqual(remaining, 0)
    }
    func testMpfSecondaryPreviewFromAndroidFixtureAndObjectSizeLimit() {
        var bytes = Data(repeating: 0, count: 82)
        bytes.replaceSubrange(0..<10, with: [255, 216, 255, 226, 0, 76, 77, 80, 70, 0])
        bytes.replaceSubrange(10..<12, with: [73, 73]); put(&bytes, 12, UInt16(42)); put(&bytes, 14, UInt32(8))
        put(&bytes, 18, UInt16(2)); put(&bytes, 20, UInt16(0xB001)); put(&bytes, 22, UInt16(4)); put(&bytes, 24, UInt32(1)); put(&bytes, 28, UInt32(2))
        put(&bytes, 32, UInt16(0xB002)); put(&bytes, 34, UInt16(7)); put(&bytes, 36, UInt32(32)); put(&bytes, 40, UInt32(38))
        put(&bytes, 48, UInt32(0x030000)); put(&bytes, 52, UInt32(1000000)); put(&bytes, 56, UInt32(0))
        put(&bytes, 64, UInt32(0x010002)); put(&bytes, 68, UInt32(123456)); put(&bytes, 72, UInt32(500000))
        bytes.replaceSubrange(80..<82, with: [255, 218])
        XCTAssertEqual(STAMediaMetadata.mpfPreviews(bytes, objectSize: 1000000), [.init(offset: 500010, length: 123456, imageType: 0x010002)])
        XCTAssertEqual(STAMediaMetadata.mpfPreviews(bytes, objectSize: 600000), [])
    }

    // NikonCamera.readStaDirectRawThumbnailInternal treats a rejected hint as
    // a miss and continues with this file's TIFF/prefix. Use actual decodable
    // JPEGs here: SOI/EOI marker-only fixtures cannot prove the grid can display it.
    func testRawRejectedOrEmptyPreviousFileHintStillLoadsCurrentThumbnail() async throws {
        for response: UInt16 in [0x200F, 0x2001] {
            let jpeg = try thumbnailJPEG()
            let first: UInt32 = 0x09000071, second: UInt32 = 0x09000072
            let firstBytes = rawThumbnailPrefix(jpeg: jpeg, jpegOffset: 140_000)
            let secondBytes = rawThumbnailPrefix(jpeg: jpeg, jpegOffset: 180_000)
            let wire = STAScriptTransport([
                .init(0x9421, [first], payload: staInteger(UInt64(24_000_000))),
                .init(0x9431, [first, 0, 0, 128 * 1024, 0], payload: Data(firstBytes.prefix(128 * 1024))),
                .init(0x9431, [first, 128 * 1024, 0, 112 * 1024, 0], payload: Data(firstBytes.dropFirst(128 * 1024))),
                .init(0x9421, [second], payload: staInteger(UInt64(24_000_000))),
                .init(0x9431, [second, 0, 0, 128 * 1024, 0], payload: Data(secondBytes.prefix(128 * 1024))),
                .init(0x9431, [second, 140_000, 0, 128 * 1024, 0], response: response),
                .init(0x9431, [second, 128 * 1024, 0, 112 * 1024, 0], payload: Data(secondBytes.dropFirst(128 * 1024))),
            ])
            let reader = STAObjectReader(session: PTPSession(transport: wire), operations: [0x9431])
            _ = try await reader.file(handle: first, storage: .max)
            _ = try await reader.thumbnail(handle: first)
            _ = try await reader.file(handle: second, storage: .max)
            let image = try await reader.thumbnail(handle: second)
            try assertThumbnailJPEG(image, expected: jpeg)
            let cached = try await reader.thumbnail(handle: second)
            XCTAssertEqual(cached, jpeg)
            let remaining = await wire.remaining; XCTAssertEqual(remaining, 0)
        }
    }

    func testRawShortHintReadsRemainingMarginLikeAndroid() async throws {
        let jpeg = try thumbnailJPEG()
        let first: UInt32 = 0x09000071, second: UInt32 = 0x09000072
        let bytes = rawThumbnailPrefix(jpeg: jpeg, jpegOffset: 140_000)
        let wire = STAScriptTransport([
            .init(0x9421, [first], payload: staInteger(UInt64(24_000_000))),
            .init(0x9431, [first, 0, 0, 128 * 1024, 0], payload: Data(bytes.prefix(128 * 1024))),
            .init(0x9431, [first, 128 * 1024, 0, 112 * 1024, 0], payload: Data(bytes.dropFirst(128 * 1024))),
            .init(0x9421, [second], payload: staInteger(UInt64(24_000_000))),
            .init(0x9431, [second, 0, 0, 128 * 1024, 0], payload: Data(bytes.prefix(128 * 1024))),
            .init(0x9431, [second, 140_000, 0, 128 * 1024, 0], payload: Data(jpeg.prefix(64))),
            .init(0x9431, [second, 140_064, 0, 192 * 1024 - 64, 0], payload: Data(jpeg.dropFirst(64))),
        ])
        let reader = STAObjectReader(session: PTPSession(transport: wire), operations: [0x9431])
        _ = try await reader.file(handle: first, storage: .max)
        _ = try await reader.thumbnail(handle: first)
        _ = try await reader.file(handle: second, storage: .max)
        let image = try await reader.thumbnail(handle: second)
        try assertThumbnailJPEG(image, expected: jpeg)
        let remaining = await wire.remaining; XCTAssertEqual(remaining, 0)
    }

    func testRawRejectedIndexedReadStillExtractsJPEGAlreadyInPrefix() async throws {
        let jpeg = try thumbnailJPEG(), handle: UInt32 = 0x09000071
        var bytes = rawThumbnailPrefix(jpeg: jpeg, jpegOffset: 140_000)
        // The SubIFD appears only in the 240 KiB probe. The camera denies its
        // referenced range, but Android still scans the bytes it already read.
        put(&bytes, 8, UInt16(1)); put(&bytes, 10, UInt16(0x014A))
        put(&bytes, 12, UInt16(4)); put(&bytes, 14, UInt32(1)); put(&bytes, 18, UInt32(200_000))
        put(&bytes, 200_000, UInt16(2))
        put(&bytes, 200_002, UInt16(0x0201)); put(&bytes, 200_004, UInt16(4))
        put(&bytes, 200_006, UInt32(1)); put(&bytes, 200_010, UInt32(300_000))
        put(&bytes, 200_014, UInt16(0x0202)); put(&bytes, 200_016, UInt16(4))
        put(&bytes, 200_018, UInt32(1)); put(&bytes, 200_022, UInt32(jpeg.count))
        let wire = STAScriptTransport([
            .init(0x9421, [handle], payload: staInteger(UInt64(24_000_000))),
            .init(0x9431, [handle, 0, 0, 128 * 1024, 0], payload: Data(bytes.prefix(128 * 1024))),
            .init(0x9431, [handle, 128 * 1024, 0, 112 * 1024, 0], payload: Data(bytes.dropFirst(128 * 1024))),
            .init(0x9431, [handle, 300_000, 0, UInt32(jpeg.count), 0], response: 0x200F),
        ])
        let reader = STAObjectReader(session: PTPSession(transport: wire), operations: [0x9431])
        _ = try await reader.file(handle: handle, storage: .max)
        let image = try await reader.thumbnail(handle: handle)
        try assertThumbnailJPEG(image, expected: jpeg)
        let remaining = await wire.remaining; XCTAssertEqual(remaining, 0)
    }

    func testRawRejectedPrefixProbeCanLoadOnNextVisibleRequest() async throws {
        let jpeg = try thumbnailJPEG(), handle: UInt32 = 0x09000071
        let bytes = rawThumbnailPrefix(jpeg: jpeg, jpegOffset: 140_000)
        let wire = STAScriptTransport([
            .init(0x9421, [handle], payload: staInteger(UInt64(24_000_000))),
            .init(0x9431, [handle, 0, 0, 128 * 1024, 0], payload: Data(bytes.prefix(128 * 1024))),
            .init(0x9431, [handle, 128 * 1024, 0, 112 * 1024, 0], response: 0x2019),
            .init(0x9431, [handle, 128 * 1024, 0, 112 * 1024, 0], payload: Data(bytes.dropFirst(128 * 1024))),
        ])
        let reader = STAObjectReader(session: PTPSession(transport: wire), operations: [0x9431])
        _ = try await reader.file(handle: handle, storage: .max)
        let busy = try await reader.thumbnail(handle: handle)
        XCTAssertTrue(busy.isEmpty)
        let image = try await reader.thumbnail(handle: handle)
        try assertThumbnailJPEG(image, expected: jpeg)
        let remaining = await wire.remaining; XCTAssertEqual(remaining, 0)
    }

    func testRawProbeTransportFailureIsNotTreatedAsARejectedRange() async throws {
        let jpeg = try thumbnailJPEG(), handle: UInt32 = 0x09000071
        let bytes = rawThumbnailPrefix(jpeg: jpeg, jpegOffset: 140_000)
        let wire = STAScriptTransport([
            .init(0x9421, [handle], payload: staInteger(UInt64(24_000_000))),
            .init(0x9431, [handle, 0, 0, 128 * 1024, 0], payload: Data(bytes.prefix(128 * 1024))),
        ])
        let failingWire = RawProbeFailureTransport(prefix: wire)
        let reader = STAObjectReader(session: PTPSession(transport: failingWire), operations: [0x9431])
        _ = try await reader.file(handle: handle, storage: .max)
        do {
            _ = try await reader.thumbnail(handle: handle)
            XCTFail("A broken transport must propagate, not continue probing")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
        let attempts = await failingWire.attempts
        XCTAssertEqual(attempts, 3)
    }

    func testExifCompressedStripsProduceDecodableBytesWithoutChangingPipelinePriority() throws {
        let jpeg = try thumbnailJPEG()
        var bytes = nefStripThumbnailFixture()
        // Replace the old marker-only fixture with two non-contiguous pieces
        // of a real JPEG and verify ImageIO can decode the assembled result.
        let split = jpeg.count / 2, secondOffset = 2_000
        bytes.append(Data(repeating: 0, count: 4_096 - bytes.count))
        put(&bytes, 132, UInt32(256)); put(&bytes, 136, UInt32(secondOffset))
        put(&bytes, 140, UInt32(split)); put(&bytes, 144, UInt32(jpeg.count - split))
        bytes.replaceSubrange(256..<(256 + split), with: jpeg.prefix(split))
        bytes.replaceSubrange(secondOffset..<(secondOffset + jpeg.count - split), with: jpeg.dropFirst(split))
        // Test the ExifInterface branch itself. Android's header caller gives
        // the earlier marker scan priority even when its range contains gaps.
        let image = try XCTUnwrap(STAMediaMetadata.nefExifThumbnail(bytes))
        try assertThumbnailJPEG(image, expected: jpeg)
    }

    private func thumbnailJPEG() throws -> Data {
        let pixels = Data(repeating: 127, count: 16 * 12 * 3)
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(width: 16, height: 12, bitsPerComponent: 8,
            bitsPerPixel: 24, bytesPerRow: 16 * 3, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return encoded as Data
    }

    func testCachedRawIndexFailureReturnsAndRetriesSameRangeWithoutExtraProbe() async throws {
        let jpeg = try thumbnailJPEG(), handle: UInt32 = 0x09000071
        var header = Data(repeating: 0, count: 128 * 1024)
        header.replaceSubrange(0..<2, with: [73, 73])
        put(&header, 2, UInt16(42)); put(&header, 4, UInt32(8)); put(&header, 8, UInt16(2))
        put(&header, 10, UInt16(0x0201)); put(&header, 12, UInt16(4)); put(&header, 14, UInt32(1)); put(&header, 18, UInt32(300_000))
        put(&header, 22, UInt16(0x0202)); put(&header, 24, UInt16(4)); put(&header, 26, UInt32(1)); put(&header, 30, UInt32(jpeg.count))
        let wire = STAScriptTransport([
            // Like Android, trust the IFD request even if metadata's size is
            // smaller than its range; do not silently skip that command.
            .init(0x9421, [handle], payload: staInteger(UInt64(header.count))),
            .init(0x9431, [handle, 0, 0, UInt32(header.count), 0], payload: header),
            .init(0x9431, [handle, 300_000, 0, UInt32(jpeg.count), 0], response: 0x2019),
            .init(0x9431, [handle, 300_000, 0, UInt32(jpeg.count), 0], payload: jpeg)
        ])
        let reader = STAObjectReader(session: PTPSession(transport: wire), operations: [0x9431])
        _ = try await reader.file(handle: handle, storage: .max)
        let miss = try await reader.thumbnail(handle: handle)
        XCTAssertTrue(miss.isEmpty)
        let remainingAfterMiss = await wire.remaining
        XCTAssertEqual(remainingAfterMiss, 1)
        try assertThumbnailJPEG(try await reader.thumbnail(handle: handle), expected: jpeg)
        let remaining = await wire.remaining; XCTAssertEqual(remaining, 0)
    }

    func testEqualLengthNefRangesKeepAndroidDirectoryOrder() {
        var header = Data(repeating: 0, count: 128)
        header.replaceSubrange(0..<2, with: [73, 73])
        put(&header, 2, UInt16(42)); put(&header, 4, UInt32(8)); put(&header, 8, UInt16(2))
        put(&header, 10, UInt16(0x0201)); put(&header, 12, UInt16(4)); put(&header, 14, UInt32(3)); put(&header, 18, UInt32(64))
        put(&header, 22, UInt16(0x0202)); put(&header, 24, UInt16(4)); put(&header, 26, UInt32(3)); put(&header, 30, UInt32(80))
        for (i, offset) in [300_000, 200_000, 300_000].enumerated() {
            put(&header, 64 + i * 4, UInt32(offset)); put(&header, 80 + i * 4, UInt32(1000))
        }
        XCTAssertEqual(STAMediaMetadata.tiffHeader(header).previews,
                       [.init(offset: 300_000, length: 1000), .init(offset: 200_000, length: 1000)])
    }

    private func rawThumbnailPrefix(jpeg: Data, jpegOffset: Int) -> Data {
        var bytes = Data(repeating: 0, count: 240 * 1024)
        bytes.replaceSubrange(0..<2, with: [73, 73])
        put(&bytes, 2, UInt16(42)); put(&bytes, 4, UInt32(8))
        bytes.replaceSubrange(jpegOffset..<(jpegOffset + jpeg.count), with: jpeg)
        return bytes
    }

    private func assertThumbnailJPEG(_ bytes: Data, expected: Data) throws {
        XCTAssertEqual(bytes, expected)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 16); XCTAssertEqual(image.height, 12)
    }
    func testMakerFileInfoHasIndependentByteOrderAndRejectsTruncation() {
        for big in [false, true] {
            var b = Data(repeating: 0, count: 96)
            b.replaceSubrange(0..<2, with: [73, 73]); put(&b, 2, UInt16(42)); put(&b, 4, UInt32(8)); put(&b, 8, UInt16(1))
            put(&b, 10, UInt16(0x8769)); put(&b, 12, UInt16(4)); put(&b, 14, UInt32(1)); put(&b, 18, UInt32(26))
            put(&b, 26, UInt16(1)); put(&b, 28, UInt16(0x927C)); put(&b, 30, UInt16(7)); put(&b, 32, UInt32(52)); put(&b, 36, UInt32(44))
            b.replaceSubrange(44..<50, with: Data("Nikon\0".utf8)); b[50] = 2; b[51] = 16; b[54] = 73; b[55] = 73
            put(&b, 56, UInt16(42)); put(&b, 58, UInt32(8)); put(&b, 62, UInt16(1)); put(&b, 64, UInt16(0x00B8))
            put(&b, 66, UInt16(7)); put(&b, 68, UInt32(10)); put(&b, 72, UInt32(32))
            b.replaceSubrange(86..<90, with: Data("0100".utf8))
            put(&b, 90, big ? UInt16(1).byteSwapped : UInt16(1))
            put(&b, 92, big ? UInt16(123).byteSwapped : UInt16(123)); put(&b, 94, big ? UInt16(4567).byteSwapped : UInt16(4567))
            XCTAssertEqual(STAMediaMetadata.makerFileNumber(b), .init(directory: 123, number: 4567))
            XCTAssertNil(STAMediaMetadata.makerFileNumber(Data(b.dropLast())))
        }
    }
    func testDirectCatalogUsesCompactIndexesWithoutFullOriginalOrObjectInfo() async throws {
        let handle: UInt32 = 0x611961F4
        let nameList = staInteger(UInt32(1)) + staInteger(handle) + staInteger(UInt16(0xDC07)) + staInteger(UInt16(0xFFFF)) + staString("DSC_8692.MP4")
        let wire = STAScriptTransport([
            .init(0x9805, [.max, 0, 0xDC07, 0, 0], payload: nameList),
            .init(0x9434, [0x10001, 0, 0], payload: metadataDate(handle: handle)),
            .init(0x9421, [handle], payload: staInteger(UInt64(5_000_000_000))),
        ])
        let reader = STAObjectReader(session: PTPSession(transport: wire), operations: [0x9805, 0x9434])
        try await reader.prepare(groups: [(0x10001, [handle])])
        let file = try await reader.file(handle: handle, storage: 0x10001)
        XCTAssertEqual(file.fileName, "DSC_8692.MP4")
        XCTAssertEqual(file.captureDate, "20260824T135715")
        XCTAssertEqual(file.size, 5_000_000_000)
        _ = try await reader.file(handle: handle, storage: 0x10001)
        // Android attempts the compact filename/date indexes once per camera
        // session; a list refresh must not resend them for every known row.
        try await reader.prepare(groups: [(0x10001, [handle])])
        let remaining = await wire.remaining; XCTAssertEqual(remaining, 0)
    }
    func testEventDecodingRejectsTruncationAndKeepsFirstParameter() {
        let payload = staInteger(UInt16(0x4002)) + staInteger(UInt32(0)) + staInteger(UInt32(12))
        XCTAssertEqual(STAEvent.socket(payload), .init(code: 0x4002, handle: 12))
        let ex = staInteger(UInt16(1)) + staInteger(UInt16(0)) + staInteger(UInt16(0x4003)) + staInteger(UInt16(2)) + staInteger(UInt32(12)) + staInteger(UInt32(55))
        XCTAssertEqual(STAEvent.polled(ex, extended: true), [.init(code: 0x4003, handle: 12)])
        XCTAssertNil(STAEvent.polled(Data(ex.dropLast()), extended: true))
    }
    private func metadataDate(handle: UInt32) -> Data {
        staInteger(UInt32(100)) + staInteger(UInt32(1)) + staInteger(handle) + staInteger(UInt32(0)) + Data([0, 15, 57, 13, 24, 8]) + staInteger(UInt16(2026))
    }
    private func nefStripThumbnailFixture() -> Data {
        var bytes = Data(repeating: 0, count: 192)
        bytes.replaceSubrange(0..<2, with: [73, 73])
        put(&bytes, 2, UInt16(42)); put(&bytes, 4, UInt32(8))

        // IFD0 points to the thumbnail IFD through the standard next-IFD link.
        put(&bytes, 8, UInt16(1))
        put(&bytes, 10, UInt16(0x0100)); put(&bytes, 12, UInt16(4))
        put(&bytes, 14, UInt32(1)); put(&bytes, 18, UInt32(6000))
        put(&bytes, 22, UInt32(40))

        put(&bytes, 40, UInt16(6))
        func entry(_ index: Int, _ tag: UInt16, _ type: UInt16, _ count: UInt32, _ value: UInt32) {
            let offset = 42 + index * 12
            put(&bytes, offset, tag); put(&bytes, offset + 2, type)
            put(&bytes, offset + 4, count); put(&bytes, offset + 8, value)
        }
        entry(0, 0x0100, 4, 1, 160)
        entry(1, 0x0101, 4, 1, 120)
        entry(2, 0x0102, 3, 3, 124)
        entry(3, 0x0103, 3, 1, 7)
        entry(4, 0x0111, 4, 2, 132)
        entry(5, 0x0117, 4, 2, 140)
        put(&bytes, 114, UInt32(0))
        put(&bytes, 124, UInt16(8)); put(&bytes, 126, UInt16(8)); put(&bytes, 128, UInt16(8))
        put(&bytes, 132, UInt32(152)); put(&bytes, 136, UInt32(176))
        put(&bytes, 140, UInt32(4)); put(&bytes, 144, UInt32(3))
        bytes.replaceSubrange(152..<156, with: [0xFF, 0xD8, 1, 2])
        bytes.replaceSubrange(176..<179, with: [3, 0xFF, 0xD9])
        return bytes
    }
    private func put<T: FixedWidthInteger>(_ data: inout Data, _ offset: Int, _ value: T) {
        data.replaceSubrange(offset..<(offset + MemoryLayout<T>.size), with: staInteger(value))
    }
}

private actor RawProbeFailureTransport: PTPCommandTransport {
    let prefix: STAScriptTransport
    private(set) var attempts = 0
    init(prefix: STAScriptTransport) { self.prefix = prefix }
    func sendPTP(command: Data, data: Data?) async throws -> (response: Data, payload: Data) {
        attempts += 1
        if attempts > 2 { throw URLError(.networkConnectionLost) }
        return try await prefix.sendPTP(command: command, data: data)
    }
}
