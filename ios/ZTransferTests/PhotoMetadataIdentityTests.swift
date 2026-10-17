import XCTest
@testable import ZTransfer

final class PhotoMetadataIdentityTests: XCTestCase {
    func testUSBThumbnailDiskCacheIsReusedOnlyByTheSameWirelessBody() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let info = try XCTUnwrap(PTPDatasetParser.parseDeviceInfo(staDeviceInfo()))
        let photo = file()
        let usbWire = STAScriptTransport([.init(PTPConstants.getThumb, [photo.id], payload: Data([1, 2, 3]))])
        let usb = CameraSession(repository: CameraRepository(session: PTPSession(transport: usbWire),
            isUSBConnection: true, deviceInfo: info, transportCameraIdentifier: "usb-device"),
            transport: ImageCaptureUSBTransport(), deviceID: "usb-device", sessionToken: UUID(),
            thumbnailStore: PhotoThumbnailStore(disk: PhotoThumbnailDiskCache(root: root)))
        let written = try await usb.prefetchThumbnailOutcome(file: photo)
        XCTAssertEqual(written, .settled)
        var otherBytes = staDeviceInfo()
        otherBytes.removeLast(staString("123").count)
        otherBytes.append(staString("456"))
        let otherInfo = try XCTUnwrap(PTPDatasetParser.parseDeviceInfo(otherBytes))
        for (deviceInfo, cached) in [(info, true), (otherInfo, false)] {
            let wire = STAScriptTransport(cached ? [] : [
                .init(PTPConstants.getThumb, [photo.id], payload: Data([4, 5, 6]))
            ])
            // Independent stores reopen the on-disk index; no memory is shared.
            let wireless = CameraSession(repository: CameraRepository(session: PTPSession(transport: wire),
                deviceInfo: deviceInfo, transportCameraIdentifier: "wifi-device"),
                thumbnailStore: PhotoThumbnailStore(disk: PhotoThumbnailDiskCache(root: root)))
            let outcome = try await wireless.prefetchThumbnailOutcome(file: photo)
            XCTAssertEqual(outcome, cached ? .cached : .settled)
            let requests = await wire.commands.count
            XCTAssertEqual(requests, cached ? 0 : 1)
        }
        let usbRequests = await usbWire.commands.count
        XCTAssertEqual(usbRequests, 1)
    }

    func testUSBAndWirelessSessionsUseBodySerialBeforeTransportFallback() async throws {
        func info(_ serial: String) throws -> PTPDeviceInfo {
            var bytes = staDeviceInfo()
            bytes.removeLast(staString("123").count)
            bytes.append(staString(serial))
            return try XCTUnwrap(PTPDatasetParser.parseDeviceInfo(bytes))
        }
        let transport = ImageCaptureUSBTransport()
        for serial in ["body-123", "", "00000000"] {
            let deviceInfo = try info(serial)
            let usbRepository = CameraRepository(session: PTPSession(transport: STAScriptTransport([])),
                isUSBConnection: true, deviceInfo: deviceInfo, transportCameraIdentifier: "usb-device")
            let usb = CameraSession(repository: usbRepository, transport: transport,
                deviceID: "usb-device", sessionToken: UUID())
            let wireless = CameraSession(repository: CameraRepository(
                session: PTPSession(transport: STAScriptTransport([])), deviceInfo: deviceInfo,
                transportCameraIdentifier: "wifi-device"))
            let usbKey = await usb.thumbnailCacheIdentity()
            let wirelessKey = await wireless.thumbnailCacheIdentity()
            if serial == "body-123" {
                XCTAssertEqual(usbKey, wirelessKey)
                XCTAssertEqual(usbKey, "Nikon\u{0}Z 30\u{0}body-123")
            } else {
                XCTAssertEqual(usbKey, "Nikon\u{0}Z 30\u{0}usb-device")
                XCTAssertNotEqual(usbKey, wirelessKey)
            }
            let other = CameraSession(repository: CameraRepository(
                session: PTPSession(transport: STAScriptTransport([])), deviceInfo: try info("other-body"),
                transportCameraIdentifier: "usb-device"))
            let otherKey = await other.thumbnailCacheIdentity()
            XCTAssertNotEqual(usbKey, otherKey)
        }
    }

    private func file(name: String = "DSC_0001.JPG", size: UInt64 = 12345,
                      date: String? = "20260929T180000", handle: UInt32 = 10) -> CameraFile {
        CameraFile(id: handle, storageID: 1, format: 0x3801, size: size,
                   fileName: name, captureDate: date, isProtected: false)
    }

    func testAndroidReconnectedSourceRequiresAllOriginalFields() {
        let original = file()
        XCTAssertTrue(samePhotoMetadataSource(original, file()))
        for other in [file(name: "DSC_0002.JPG"), file(size: 12346), file(date: "20260930T180000"), file(handle: 11)] {
            XCTAssertFalse(samePhotoMetadataSource(original, other))
        }
        XCTAssertFalse(samePhotoMetadataSource(original, nil))
        XCTAssertFalse(samePhotoMetadataSource(file(date: nil), file(date: nil)))
        XCTAssertFalse(samePhotoMetadataSource(file(date: " \n"), file(date: " \n")))
        XCTAssertFalse(samePhotoMetadataSource(file(size: 0), file(size: 0)))
    }

    func testKnownBodySharesIdentityButUnknownBodyIsSessionLocal() {
        let known = "Nikon\u{0}Z 30\u{0}serial-123"
        XCTAssertEqual(PhotoMetadataCameraIdentity(cacheIdentity: known, session: "first").camera,
                       PhotoMetadataCameraIdentity(cacheIdentity: known, session: "second").camera)
        let unknown = "Nikon\u{0}Z 30\u{0}unknown-device"
        XCTAssertNotEqual(PhotoMetadataCameraIdentity(cacheIdentity: unknown, session: "first").camera,
                          PhotoMetadataCameraIdentity(cacheIdentity: unknown, session: "second").camera)
    }

    func testSTAObjectInfoDoesNotConsumeUnreliableProtectionField() throws {
        var object = Data(repeating: 0, count: 52)
        object.replaceSubrange(0..<4, with: staInteger(UInt32(1)))
        object.replaceSubrange(4..<6, with: staInteger(UInt16(0x3801)))
        object.replaceSubrange(6..<8, with: staInteger(UInt16(1)))
        object.replaceSubrange(8..<12, with: staInteger(UInt32(12345)))
        object.append(staString("DSC_0001.JPG"))
        object.append(staString("20260929T180000"))
        let sta = try XCTUnwrap(PTPDatasetParser.parseObjectInfo(
            handle: 10, object, protectionAvailable: false
        ))
        let ap = try XCTUnwrap(PTPDatasetParser.parseObjectInfo(
            handle: 10, object, protectionAvailable: true
        ))
        XCTAssertFalse(sta.isProtected)
        XCTAssertTrue(ap.isProtected)
    }

    func testReconnectedReadVerifiesObjectBeforeHeaderAndRejectsMismatch() async throws {
        let expected = file()
        let info = try XCTUnwrap(PTPDatasetParser.parseDeviceInfo(staDeviceInfo()))
        for matches in [true, false] {
            var object = Data(repeating: 0, count: 52)
            object.replaceSubrange(0..<4, with: staInteger(UInt32(1)))
            object.replaceSubrange(4..<6, with: staInteger(UInt16(0x3801)))
            object.replaceSubrange(8..<12, with: staInteger(UInt32(expected.size)))
            object.append(staString(matches ? expected.fileName : "OTHER.JPG"))
            object.append(staString(expected.captureDate!))
            var steps: [STAExchange] = [.init(PTPConstants.getObjectInfo, [10], payload: object)]
            if matches {
                steps.append(.init(PTPConstants.getPartialObjectEx,
                    [10, 0, 0, UInt32(cameraExifHeaderCaptureBytes), 0], payload: Data([1, 2, 3])))
            }
            let wire = STAScriptTransport(steps)
            let repository = CameraRepository(session: PTPSession(transport: wire), deviceInfo: info)
            let identity = await repository.photoMetadataIdentity()
            let original = PhotoMetadataCameraIdentity(cacheIdentity: identity.camera, session: "previous-session")
            let result = try await repository.frameMetadataHeader(file: expected, expectedSource: original)
            XCTAssertEqual(result, matches ? Data([1, 2, 3]) : nil)
            let remaining = await wire.remaining
            XCTAssertEqual(remaining, 0)
        }
    }

    func testDifferentBodyAndUnknownReconnectionNeverReadCamera() async throws {
        let wire = STAScriptTransport([])
        let repository = CameraRepository(session: PTPSession(transport: wire))
        let identity = await repository.photoMetadataIdentity()
        let previousUnknown = PhotoMetadataCameraIdentity(cacheIdentity: "\u{0}\u{0}unknown-device", session: "old")
        XCTAssertNotEqual(identity.camera, previousUnknown.camera)
        for source in [previousUnknown, PhotoMetadataCameraIdentity(cacheIdentity: "other-body", session: "old")] {
            let header = try await repository.frameMetadataHeader(file: file(), expectedSource: source)
            XCTAssertNil(header)
        }
        let commands = await wire.commands
        XCTAssertTrue(commands.isEmpty)
    }
}
