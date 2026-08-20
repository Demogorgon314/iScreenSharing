import Network
import XCTest
@testable import iShareScreen

final class BonjourBrowserTests: XCTestCase {
    func testConvertsServiceEndpointToDomainModel() throws {
        let networkEndpoint = NWEndpoint.service(
            name: "Shared Mac",
            type: "_rfb._tcp",
            domain: "local.",
            interface: nil
        )

        let endpoint = try XCTUnwrap(BonjourBrowser.connectionEndpoint(from: networkEndpoint))

        XCTAssertEqual(endpoint.displayName, "Shared Mac")
        XCTAssertEqual(endpoint.bonjourService?.type, "_rfb._tcp")
        XCTAssertEqual(endpoint.bonjourService?.domain, "local.")
    }

    func testIgnoresNonServiceEndpoint() {
        XCTAssertNil(
            BonjourBrowser.connectionEndpoint(
                from: .hostPort(host: "example.local", port: 5900)
            )
        )
    }
}
