import XCTest
@testable import ZTransfer

final class ImageCaptureErrorMappingTests: XCTestCase {
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
        for code in [-20098, -9937, -21350, -21349, -21348, -9901, -9902] {
            XCTAssertEqual(
                ImageCaptureUSBTransport.mapForTesting(NSError(domain: "ICErrorDomain", code: code)),
                .disconnected,
                "unexpected mapping for ImageCaptureCore code \(code)"
            )
        }
    }
}
