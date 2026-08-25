import Network
import XCTest
@testable import iShareScreen

final class NWConnectionTransportTests: XCTestCase {
    func testEnablesTCPNoDelayWithoutChangingServiceClass() throws {
        let parameters = NWConnectionTransport.networkParameters()
        let tcpOptions = try XCTUnwrap(
            parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options
        )

        XCTAssertTrue(tcpOptions.noDelay)
        XCTAssertEqual(parameters.serviceClass, .bestEffort)
    }

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

    func testCreatesEndpointFromSelectedIPv4Address() throws {
        let address = try ResolvedRemoteAddress(
            numericHost: "192.168.50.239",
            port: 5901
        )

        XCTAssertEqual(
            NWConnectionTransport.networkEndpoint(for: address),
            .hostPort(host: "192.168.50.239", port: 5901)
        )
    }

    func testCreatesEndpointFromSelectedIPv6Address() throws {
        let address = try ResolvedRemoteAddress(
            numericHost: "2001:db8::1",
            port: 5900
        )

        XCTAssertEqual(
            NWConnectionTransport.networkEndpoint(for: address),
            .hostPort(host: "2001:db8::1", port: 5900)
        )
    }
}
