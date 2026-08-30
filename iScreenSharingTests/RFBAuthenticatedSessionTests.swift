import Foundation
import struct ScreenSharingProtocol.RFBServerInfo
import XCTest
@testable import iScreenSharing

final class RFBAuthenticatedSessionTests: XCTestCase {
    func testKeepsSelectedAddressForControlAndMediaWithoutChangingConnectionIdentity() throws {
        let endpoint = ConnectionEndpoint(
            bonjourService: try BonjourServiceEndpoint(name: "Shared Mac")
        )
        let remoteAddress = try ResolvedRemoteAddress(
            numericHost: "192.168.50.239",
            port: 5900
        )
        let session = RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: remoteAddress,
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(
                width: 1920,
                height: 1080,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Shared Mac"
            ),
            transport: NWConnectionTransport(remoteAddress: remoteAddress)
        )

        XCTAssertEqual(session.endpoint, endpoint)
        XCTAssertEqual(session.remoteAddress.numericHost, "192.168.50.239")
        XCTAssertEqual(session.remoteAddress.port, 5900)
    }
}
