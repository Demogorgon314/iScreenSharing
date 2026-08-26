import Darwin
import XCTest
@testable import iScreenSharing

final class TailscaleMediaReceiverTests: XCTestCase {
    func testFormatsPacketAddressesForBothIPFamilies() {
        XCTAssertEqual(
            TailscaleMediaReceiver.address(host: "100.64.0.10", port: 5900),
            "100.64.0.10:5900"
        )
        XCTAssertEqual(
            TailscaleMediaReceiver.address(host: "fd7a:115c:a1e0::1", port: 5901),
            "[fd7a:115c:a1e0::1]:5901"
        )
    }

    func testSelectsLocalAddressMatchingRemoteFamily() {
        let addresses = ["100.64.0.20", "fd7a:115c:a1e0::2"]

        XCTAssertEqual(
            TailscaleMediaReceiver.localHost(matching: sa_family_t(AF_INET), from: addresses),
            "100.64.0.20"
        )
        XCTAssertEqual(
            TailscaleMediaReceiver.localHost(matching: sa_family_t(AF_INET6), from: addresses),
            "fd7a:115c:a1e0::2"
        )
        XCTAssertNil(TailscaleMediaReceiver.localHost(matching: sa_family_t(AF_UNIX), from: addresses))
    }
}
