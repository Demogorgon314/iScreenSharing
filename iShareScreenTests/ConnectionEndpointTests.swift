import XCTest
@testable import iShareScreen

final class ConnectionEndpointTests: XCTestCase {
    func testParsesHostnameWithDefaultPort() throws {
        let endpoint = try ConnectionEndpoint("deepdream.local")

        XCTAssertEqual(endpoint.host, "deepdream.local")
        XCTAssertEqual(endpoint.port, 5900)
        XCTAssertEqual(endpoint.displayName, "deepdream.local")
        XCTAssertEqual(endpoint.url.absoluteString, "vnc://deepdream.local")
    }

    func testParsesVNCURLAndCustomPort() throws {
        let endpoint = try ConnectionEndpoint("vnc://192.168.50.239:5901")

        XCTAssertEqual(endpoint.host, "192.168.50.239")
        XCTAssertEqual(endpoint.port, 5901)
        XCTAssertEqual(endpoint.displayName, "192.168.50.239:5901")
    }

    func testParsesBracketedIPv6() throws {
        let endpoint = try ConnectionEndpoint("[fe80::1]:5900")

        XCTAssertEqual(endpoint.host, "fe80::1")
        XCTAssertEqual(endpoint.port, 5900)
    }

    func testRepresentsBonjourServiceWithoutFrameworkDependencies() throws {
        let service = try BonjourServiceEndpoint(name: "deepdream’s Mac mini")
        let endpoint = ConnectionEndpoint(bonjourService: service)

        XCTAssertEqual(endpoint.displayName, "deepdream’s Mac mini")
        XCTAssertEqual(endpoint.bonjourService, service)
        XCTAssertTrue(endpoint.url.absoluteString.hasPrefix("vnc://bonjour?"))
        XCTAssertEqual(
            try JSONDecoder().decode(ConnectionEndpoint.self, from: JSONEncoder().encode(endpoint)),
            endpoint
        )
    }

    func testRejectsEmptyBonjourServiceFields() {
        XCTAssertThrowsError(try BonjourServiceEndpoint(name: " "))
        XCTAssertThrowsError(try BonjourServiceEndpoint(name: "Mac", type: " "))
        XCTAssertThrowsError(try BonjourServiceEndpoint(name: "Mac", domain: " "))
    }

    func testRejectsEmptyAndMalformedInputs() {
        XCTAssertThrowsError(try ConnectionEndpoint(""))
        XCTAssertThrowsError(try ConnectionEndpoint("not a host/path"))
        XCTAssertThrowsError(try ConnectionEndpoint("http://example.com"))
        XCTAssertThrowsError(try ConnectionEndpoint("vnc://user@example.com"))
    }
}
