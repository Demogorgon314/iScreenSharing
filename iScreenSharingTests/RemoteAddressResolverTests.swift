import Darwin
import XCTest
@testable import iScreenSharing

final class RemoteAddressResolverTests: XCTestCase {
    func testParsesNumericIPv4AddressAndPort() throws {
        let address = try ResolvedRemoteAddress(
            numericHost: "192.168.50.239",
            port: 5901
        )

        XCTAssertEqual(address.family, sa_family_t(AF_INET))
        XCTAssertEqual(address.numericHost, "192.168.50.239")
        XCTAssertEqual(address.port, 5901)
    }

    func testParsesNumericIPv6AddressAndPort() throws {
        let address = try ResolvedRemoteAddress(
            numericHost: "2001:db8::1",
            port: 5902
        )

        XCTAssertEqual(address.family, sa_family_t(AF_INET6))
        XCTAssertEqual(address.numericHost, "2001:db8::1")
        XCTAssertEqual(address.port, 5902)
    }

    func testPrioritizesIPv4WhilePreservingOrderWithinEachFamily() throws {
        let ipv6One = try ResolvedRemoteAddress(numericHost: "2001:db8::1", port: 5900)
        let ipv4One = try ResolvedRemoteAddress(numericHost: "192.0.2.1", port: 5900)
        let ipv6Two = try ResolvedRemoteAddress(numericHost: "2001:db8::2", port: 5900)
        let ipv4Two = try ResolvedRemoteAddress(numericHost: "192.0.2.2", port: 5900)

        XCTAssertEqual(
            RemoteAddressResolver.prioritized([
                ipv6One,
                ipv4One,
                ipv6Two,
                ipv4Two,
            ]).map(\.numericHost),
            ["192.0.2.1", "192.0.2.2", "2001:db8::1", "2001:db8::2"]
        )
    }

    func testRewritesPortWithoutChangingAddressFamily() throws {
        let address = try ResolvedRemoteAddress(numericHost: "2001:db8::1", port: 5900)

        let values = address.withSockAddr(port: 6000) { pointer, length in
            (pointer.pointee.sa_family, length, pointer.withMemoryRebound(
                to: sockaddr_in6.self,
                capacity: 1
            ) { UInt16(bigEndian: $0.pointee.sin6_port) })
        }

        XCTAssertEqual(values.0, sa_family_t(AF_INET6))
        XCTAssertEqual(values.1, socklen_t(MemoryLayout<sockaddr_in6>.size))
        XCTAssertEqual(values.2, 6000)
    }

    func testPreservesIPv6LinkLocalScope() throws {
        let scopeID = if_nametoindex("lo0")
        XCTAssertNotEqual(scopeID, 0)
        let address = try ResolvedRemoteAddress(
            numericHost: "fe80::1%lo0",
            port: 5900
        )

        let resolvedScopeID = address.withSockAddr(port: address.port) { pointer, _ in
            pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                $0.pointee.sin6_scope_id
            }
        }

        XCTAssertEqual(resolvedScopeID, scopeID)
        XCTAssertTrue(address.numericHost.hasSuffix("%lo0"))
    }

    func testResolvesConfiguredBonjourServiceWithIPv4First() async throws {
        guard let name = ProcessInfo.processInfo.environment[
            "ISHARESCREEN_TEST_BONJOUR_NAME"
        ] else {
            throw XCTSkip("Set ISHARESCREEN_TEST_BONJOUR_NAME to run the Bonjour resolver test.")
        }
        let endpoint = ConnectionEndpoint(
            bonjourService: try BonjourServiceEndpoint(name: name)
        )

        let addresses = try await RemoteAddressResolver().resolve(endpoint)

        XCTAssertFalse(addresses.isEmpty)
        if addresses.contains(where: { Int32($0.family) == AF_INET }) {
            XCTAssertEqual(Int32(addresses[0].family), AF_INET)
        }
    }
}
