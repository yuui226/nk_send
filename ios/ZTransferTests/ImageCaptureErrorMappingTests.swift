import ImageCaptureCore
import XCTest
@testable import ZTransfer

final class ImageCaptureErrorMappingTests: XCTestCase {
    func testImageCaptureCompletionKeepsInDataSeparateFromPTPResponse() {
        let payload = Data([1, 2, 3])
        let response = Data([12, 0, 0, 0, 3, 0, 1, 32])
        let result = ImageCaptureUSBTransport.ptpResultForTesting(inData: payload, response: response)
        XCTAssertEqual(result.response, response)
        XCTAssertEqual(result.payload, payload)
    }

    func testUSBRequiresBothContentsAndControlAuthorization() {
        XCTAssertEqual(
            ImageCaptureUSBTransport.combinedAuthorizationForTesting(
                contents: .authorized,
                control: .authorized
            ),
            .authorized
        )
        XCTAssertEqual(
            ImageCaptureUSBTransport.combinedAuthorizationForTesting(
                contents: .authorized,
                control: .notDetermined
            ),
            .notDetermined
        )
        XCTAssertEqual(
            ImageCaptureUSBTransport.combinedAuthorizationForTesting(
                contents: .denied,
                control: .authorized
            ),
            .denied
        )
        XCTAssertEqual(
            ImageCaptureUSBTransport.combinedAuthorizationForTesting(
                contents: .authorized,
                control: .restricted
            ),
            .restricted
        )
    }

    func testImageCaptureTimeoutAndPermissionCategoriesMatchTransportErrors() {
        XCTAssertEqual(
            ImageCaptureUSBTransport.mapForTesting(NSError(domain: "ICErrorDomain", code: -9923)),
            .timeout
        )
        XCTAssertEqual(
            ImageCaptureUSBTransport.mapForTesting(NSError(domain: "ICErrorDomain", code: -21343)),
            .permissionDenied
        )
    }

    func testImageCaptureDisconnectCategoriesDoNotBecomeProtocolFailures() {
        for code in [
            -20098, -9937,
            -21350, -21349, -21348, -21347, -21345, -21344,
            -21250,
            -9900, -9901, -9902, -9914, -9921, -9927, -9928,
            -9936, -9956, -9957, -9958,
        ] {
            XCTAssertEqual(
                ImageCaptureUSBTransport.mapForTesting(NSError(domain: "ICErrorDomain", code: code)),
                .disconnected,
                "unexpected mapping for ImageCaptureCore code \(code)"
            )
        }
    }
}
