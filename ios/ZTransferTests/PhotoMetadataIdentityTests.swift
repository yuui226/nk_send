import XCTest
@testable import ZTransfer

final class PhotoMetadataIdentityTests: XCTestCase {
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
