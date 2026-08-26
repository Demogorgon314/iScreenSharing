import XCTest
@testable import iScreenSharing

@MainActor
final class TailscaleModelTests: XCTestCase {
    func testPublishesRuntimeStatePeersAndAuthenticationURL() async throws {
        let peer = TailscalePeer(
            id: "node-1",
            name: "Studio Mac",
            dnsName: "studio.example.ts.net",
            addresses: ["100.64.0.10"],
            isOnline: true
        )
        let url = try XCTUnwrap(URL(string: "https://login.tailscale.com/a/example"))
        let runtime = MockEmbeddedTailscaleRuntime(events: [
            .state(.needsLogin),
            .peers([peer]),
            .authenticationURL(url),
        ])
        let model = TailscaleModel(runtime: runtime)

        model.start()
        for _ in 0..<100 where model.authenticationURL == nil {
            await Task.yield()
        }

        XCTAssertEqual(model.state, .needsLogin)
        XCTAssertEqual(model.peers, [peer])
        XCTAssertEqual(model.authenticationURL, url)
    }

    func testReportsLoginFailureWithoutExposingRuntimeDetails() async {
        let runtime = MockEmbeddedTailscaleRuntime(loginError: TestError())
        let model = TailscaleModel(runtime: runtime)

        model.start()
        for _ in 0..<100 where await !runtime.didStart {
            await Task.yield()
        }
        model.linkAccount()
        for _ in 0..<100 {
            if case .failed = model.state { break }
            await Task.yield()
        }

        let loginCount = await runtime.loginCount
        XCTAssertEqual(model.state, .failed("Test login failed"))
        XCTAssertEqual(loginCount, 1)
        XCTAssertFalse(model.isLinkingAccount)
    }

    func testKeepsLoginPendingUntilAuthenticationURLArrivesAndIgnoresDuplicateClicks() async throws {
        let runtime = MockEmbeddedTailscaleRuntime()
        let model = TailscaleModel(runtime: runtime)
        let url = try XCTUnwrap(URL(string: "https://login.tailscale.com/a/example"))

        model.start()
        for _ in 0..<100 where await !runtime.didStart {
            await Task.yield()
        }
        model.linkAccount()
        model.linkAccount()
        for _ in 0..<100 where await runtime.loginCount == 0 {
            await Task.yield()
        }

        XCTAssertTrue(model.isLinkingAccount)
        let loginCount = await runtime.loginCount
        XCTAssertEqual(loginCount, 1)

        await runtime.send(.authenticationURL(url))
        for _ in 0..<100 where model.authenticationURL == nil {
            await Task.yield()
        }

        XCTAssertEqual(model.authenticationURL, url)
        XCTAssertFalse(model.isLinkingAccount)
    }

    func testPeerCreatesTailscaleRoutedEndpoint() throws {
        let peer = TailscalePeer(
            id: "node-1",
            name: "Studio Mac",
            dnsName: "studio.example.ts.net",
            addresses: ["fd7a:115c:a1e0::1", "100.64.0.10"],
            isOnline: true
        )

        let endpoint = try XCTUnwrap(peer.endpoint)

        XCTAssertEqual(endpoint.host, "100.64.0.10")
        XCTAssertEqual(endpoint.route, .tailscale)
    }

    func testPeerCreatesRemoteDeviceInfoFromTailscaleDeviceModel() throws {
        let peer = TailscalePeer(
            id: "node-1",
            name: "Studio Mac",
            dnsName: "studio.example.ts.net",
            addresses: ["100.64.0.10"],
            isOnline: true,
            deviceModel: "Macmini9,1"
        )

        XCTAssertEqual(peer.deviceInfo?.modelIdentifier, "Macmini9,1")
    }

    func testPeerDescribesOperatingSystemAndTailscaleVersion() {
        let peer = TailscalePeer(
            id: "node-1",
            name: "Studio Mac",
            dnsName: "studio.example.ts.net",
            addresses: ["100.64.0.10"],
            isOnline: true,
            operatingSystem: "macOS",
            operatingSystemVersion: "15.7.7",
            tailscaleVersion: "1.102.3"
        )

        XCTAssertEqual(peer.softwareDescription, "macOS 15.7.7 · Tailscale 1.102.3")
    }

    func testPeerOmitsUnavailableSoftwareMetadata() {
        let peer = TailscalePeer(
            id: "node-1",
            name: "Studio Mac",
            dnsName: "studio.example.ts.net",
            addresses: ["100.64.0.10"],
            isOnline: false
        )

        XCTAssertNil(peer.softwareDescription)
    }

    func testPeerNormalizesCommonOperatingSystemNames() {
        let peer = TailscalePeer(
            id: "node-1",
            name: "Server",
            dnsName: "server.example.ts.net",
            addresses: ["100.64.0.10"],
            isOnline: true,
            operatingSystem: "linux"
        )

        XCTAssertEqual(peer.softwareDescription, "Linux")
    }
}

private actor MockEmbeddedTailscaleRuntime: EmbeddedTailscaleRunning {
    private let initialEvents: [EmbeddedTailscaleEvent]
    private let loginError: Error?
    private var continuation: AsyncStream<EmbeddedTailscaleEvent>.Continuation?
    private(set) var didStart = false
    private(set) var loginCount = 0

    init(
        events: [EmbeddedTailscaleEvent] = [],
        loginError: Error? = nil
    ) {
        initialEvents = events
        self.loginError = loginError
    }

    func events() -> AsyncStream<EmbeddedTailscaleEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func start() {
        didStart = true
        for event in initialEvents {
            continuation?.yield(event)
        }
    }

    func startLogin() throws {
        loginCount += 1
        if let loginError { throw loginError }
    }

    func send(_ event: EmbeddedTailscaleEvent) {
        continuation?.yield(event)
    }
}

private struct TestError: LocalizedError {
    var errorDescription: String? { "Test login failed" }
}
