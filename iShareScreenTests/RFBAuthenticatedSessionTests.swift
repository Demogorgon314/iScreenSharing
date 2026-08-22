import Foundation
import XCTest
@testable import iShareScreen

final class RFBAuthenticatedSessionTests: XCTestCase {
    func testUsesResolvedIPv4HostForBonjourMediaWithoutChangingConnectionIdentity() throws {
        let endpoint = ConnectionEndpoint(
            bonjourService: try BonjourServiceEndpoint(name: "Shared Mac")
        )
        let session = RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteIPv4Host: "192.168.50.239",
            serverVersion: RFBVersion(major: 3, minor: 889),
            securityTypes: [.appleRSA],
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(
                width: 1920,
                height: 1080,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Shared Mac"
            ),
            transport: NWConnectionTransport(endpoint: endpoint)
        )

        XCTAssertEqual(session.endpoint, endpoint)
        XCTAssertEqual(session.mediaHost, "192.168.50.239")
    }

    func testFallsBackToEndpointHostWhenTransportHasNoResolvedIPv4Address() throws {
        let endpoint = try ConnectionEndpoint("example.local")
        let session = RFBAuthenticatedSession(
            endpoint: endpoint,
            serverVersion: RFBVersion(major: 3, minor: 889),
            securityTypes: [.appleRSA],
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(
                width: 1920,
                height: 1080,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Shared Mac"
            ),
            transport: NWConnectionTransport(endpoint: endpoint)
        )

        XCTAssertEqual(session.mediaHost, "example.local")
    }
}
