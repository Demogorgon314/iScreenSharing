import Foundation
import struct ScreenSharingProtocol.RFBServerInfo
import XCTest
@testable import iScreenSharing

@MainActor
final class SessionManagerTests: XCTestCase {
    func testDisconnectsOnlyTailscaleSessions() throws {
        let directEndpoint = try ConnectionEndpoint(host: "direct.example")
        let tailscaleEndpoint = try ConnectionEndpoint(
            host: "100.64.0.10",
            route: .tailscale
        )
        let directSession = try makeSession(endpoint: directEndpoint)
        let tailscaleSession = try makeSession(endpoint: tailscaleEndpoint)
        let manager = SessionManager()
        manager.install(directSession)
        manager.install(tailscaleSession)

        XCTAssertEqual(manager.tailscaleSessionCount, 1)

        manager.disconnectTailscaleSessions()

        XCTAssertTrue(manager.session(for: directEndpoint) === directSession)
        XCTAssertNil(manager.session(for: tailscaleEndpoint))
        XCTAssertEqual(manager.tailscaleSessionCount, 0)
    }

    private func makeSession(endpoint: ConnectionEndpoint) throws -> RFBAuthenticatedSession {
        let remoteAddress = try ResolvedRemoteAddress(
            numericHost: "127.0.0.1",
            port: endpoint.port
        )
        return RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: remoteAddress,
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(
                width: 1920,
                height: 1080,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Test Mac"
            ),
            transport: NWConnectionTransport(remoteAddress: remoteAddress)
        )
    }
}
