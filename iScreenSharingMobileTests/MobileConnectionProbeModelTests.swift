import XCTest
@testable import iScreenSharingMobile

@MainActor
final class MobileConnectionProbeModelTests: XCTestCase {
    func testBecomesReadyForAppleRSAHost() async throws {
        let endpoint = try ConnectionEndpoint(host: "studio-mac.local")
        let model = MobileConnectionProbeModel(
            endpoint: endpoint,
            probe: MockRFBProbe(result: RFBProbeResult(
                serverVersion: RFBVersion(major: 3, minor: 889),
                securityTypes: [.appleRSA]
            ))
        )

        await model.start()

        XCTAssertEqual(model.state, .ready)
    }

    func testReportsUnsupportedAuthentication() async throws {
        let endpoint = try ConnectionEndpoint(host: "legacy-mac.local")
        let model = MobileConnectionProbeModel(
            endpoint: endpoint,
            probe: MockRFBProbe(result: RFBProbeResult(
                serverVersion: RFBVersion(major: 3, minor: 8),
                securityTypes: [.none]
            ))
        )

        await model.start()

        XCTAssertEqual(model.state, .unsupported)
    }

    func testPublishesProbeFailure() async throws {
        let endpoint = try ConnectionEndpoint(host: "offline.local")
        let model = MobileConnectionProbeModel(
            endpoint: endpoint,
            probe: MockRFBProbe(error: TestError.offline)
        )

        await model.start()

        XCTAssertEqual(model.state, .failed("The Mac is offline."))
    }
}

private struct MockRFBProbe: RFBProbing {
    var result: RFBProbeResult?
    var error: Error?

    init(result: RFBProbeResult? = nil, error: Error? = nil) {
        self.result = result
        self.error = error
    }

    func probe(_ endpoint: ConnectionEndpoint) async throws -> RFBProbeResult {
        if let error { throw error }
        return try XCTUnwrap(result)
    }
}

private enum TestError: LocalizedError {
    case offline

    var errorDescription: String? { "The Mac is offline." }
}
