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

    func testExtractsIPv4HostFromResolvedPathEndpoint() throws {
        let address = try XCTUnwrap(IPv4Address("192.168.50.239"))
        let endpoint = NWEndpoint.hostPort(host: .ipv4(address), port: 5900)

        XCTAssertEqual(
            NWConnectionTransport.ipv4Host(from: endpoint),
            "192.168.50.239"
        )
    }

    func testDoesNotTreatUnresolvedOrIPv6EndpointAsIPv4() throws {
        let address = try XCTUnwrap(IPv6Address("fe80::1"))

        XCTAssertNil(
            NWConnectionTransport.ipv4Host(
                from: .hostPort(host: .name("example.local", nil), port: 5900)
            )
        )
        XCTAssertNil(
            NWConnectionTransport.ipv4Host(
                from: .hostPort(host: .ipv6(address), port: 5900)
            )
        )
    }

    func testIPv4ParametersRequireIPv4ForHighPerformanceSessions() throws {
        let parameters = NWConnectionTransport.parameters(requiresIPv4: true)
        let options = try XCTUnwrap(
            parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options
        )

        XCTAssertEqual(options.version, .v4)
    }
}
