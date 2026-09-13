import XCTest
@testable import ZTransferProtocol

final class PTPIPDiscoveryTests: XCTestCase {
    func testScanUsesLocal24AndExcludesLocalAddress() {
        let hosts = PTPIPDiscoveryPolicy.candidates(localAddress: "192.168.5.27", routePrefix: 16).map(\.ip)
        XCTAssertEqual(hosts.count, 253)
        XCTAssertFalse(hosts.contains("192.168.5.27"))
        XCTAssertTrue(hosts.contains("192.168.5.1"))
        XCTAssertTrue(hosts.contains("192.168.5.254"))
    }

    func testCameraHotspotSubnetGateMatchesAndroidFixedGateway() {
        XCTAssertTrue(PTPIPDiscoveryPolicy.isCameraHotspotAddress("192.168.1.2"))
        XCTAssertTrue(PTPIPDiscoveryPolicy.isCameraHotspotAddress("192.168.1.254"))
        XCTAssertFalse(PTPIPDiscoveryPolicy.isCameraHotspotAddress("192.168.5.27"))
        XCTAssertFalse(PTPIPDiscoveryPolicy.isCameraHotspotAddress("bad"))
    }

    func testContainsRejectsMalformedAndLocalAddress() {
        XCTAssertTrue(PTPIPDiscoveryPolicy.contains(localAddress: "192.168.5.27", candidate: "192.168.5.99", prefix: 24))
        XCTAssertFalse(PTPIPDiscoveryPolicy.contains(localAddress: "192.168.5.27", candidate: "192.168.6.99", prefix: 24))
        XCTAssertFalse(PTPIPDiscoveryPolicy.contains(localAddress: "192.168.5.27", candidate: "192.168.5.27", prefix: 24))
        XCTAssertFalse(PTPIPDiscoveryPolicy.contains(localAddress: "bad", candidate: "192.168.5.99", prefix: 24))
    }
}
