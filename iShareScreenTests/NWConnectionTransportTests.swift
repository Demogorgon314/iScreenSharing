import Network
import XCTest
@testable import iShareScreen

final class NWConnectionTransportTests: XCTestCase {
    func testCreatesHostPortEndpoint() throws {
        let endpoint = try ConnectionEndpoint(host: "example.local", port: 5901)

        XCTAssertEqual(
            NWConnectionTransport.networkEndpoint(for: endpoint),
            .hostPort(host: "example.local", port: 5901)
        )
    }

    func testCreatesBonjourServiceEndpoint() throws {
        let endpoint = ConnectionEndpoint(
            bonjourService: try BonjourServiceEndpoint(
                name: "Test Mac",
                type: "_rfb._tcp",
                domain: "local."
            )
        )

        XCTAssertEqual(
            NWConnectionTransport.networkEndpoint(for: endpoint),
            .service(
                name: "Test Mac",
                type: "_rfb._tcp",
                domain: "local.",
                interface: nil
            )
        )
    }
}
