import XCTest
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
    private func put<T: FixedWidthInteger>(_ data: inout Data, _ offset: Int, _ value: T) {
        data.replaceSubrange(offset..<(offset + MemoryLayout<T>.size), with: staInteger(value))
    }
}
