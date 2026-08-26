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
}

private struct TestError: LocalizedError {
    var errorDescription: String? { "Test login failed" }
}
