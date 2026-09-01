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

    func testLogoutClearsAccountState() async throws {
        let peer = TailscalePeer(
            id: "node-1",
            name: "Studio Mac",
            dnsName: "studio.example.ts.net",
            addresses: ["100.64.0.10"],
            isOnline: true
        )
        let url = try XCTUnwrap(URL(string: "https://login.tailscale.com/a/example"))
        let runtime = MockEmbeddedTailscaleRuntime(events: [
            .state(.running),
            .peers([peer]),
            .authenticationURL(url),
        ])
        let model = TailscaleModel(runtime: runtime)

        model.start()
        for _ in 0..<100 where model.authenticationURL == nil {
            await Task.yield()
        }
        await model.logout()

        let logoutCount = await runtime.logoutCount
        XCTAssertEqual(logoutCount, 1)
        XCTAssertEqual(model.state, .needsLogin)
        XCTAssertTrue(model.peers.isEmpty)
        XCTAssertNil(model.authenticationURL)
        XCTAssertFalse(model.isLoggingOut)
        XCTAssertNil(model.logoutErrorMessage)
    }

    func testLogoutFailureKeepsAccountStateAndShowsSafeError() async {
        let runtime = MockEmbeddedTailscaleRuntime(
            events: [.state(.running)],
            logoutError: TestError()
        )
        let model = TailscaleModel(runtime: runtime)

        model.start()
        for _ in 0..<100 where model.state != .running {
            await Task.yield()
        }
        await model.logout()

        XCTAssertEqual(model.state, .running)
        XCTAssertEqual(model.logoutErrorMessage, "Couldn’t log out of Tailscale. Try again.")
        XCTAssertFalse(model.isLoggingOut)
    }

    func testNeedsLoginStateClearsStaleAccountData() async throws {
        let peer = TailscalePeer(
            id: "node-1",
            name: "Studio Mac",
            dnsName: "studio.example.ts.net",
            addresses: ["100.64.0.10"],
            isOnline: true
        )
        let url = try XCTUnwrap(URL(string: "https://login.tailscale.com/a/example"))
        let runtime = MockEmbeddedTailscaleRuntime(events: [
            .peers([peer]),
            .authenticationURL(url),
            .state(.needsLogin),
        ])
        let model = TailscaleModel(runtime: runtime)

        model.start()
        for _ in 0..<100 where model.state != .needsLogin || !model.peers.isEmpty {
            await Task.yield()
        }

        XCTAssertTrue(model.peers.isEmpty)
        XCTAssertNil(model.authenticationURL)
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

    func testPeerVisibilityShowsMacOSAndUnknownDevicesByDefault() {
        let macOSPeer = makePeer(id: "macos", operatingSystem: "macOS")
        let darwinPeer = makePeer(id: "darwin", operatingSystem: "darwin")
        let unknownPeer = makePeer(id: "unknown", operatingSystem: nil)
        let blankPeer = makePeer(id: "blank", operatingSystem: "  ")
        let linuxPeer = makePeer(id: "linux", operatingSystem: "linux")

        XCTAssertEqual(
            TailscalePeerVisibility.filteredPeers(
                [macOSPeer, darwinPeer, unknownPeer, blankPeer, linuxPeer],
                showsOtherOperatingSystems: false
            ),
            [macOSPeer, darwinPeer, unknownPeer, blankPeer]
        )
    }

    func testPeerVisibilityCanShowEveryOperatingSystem() {
        let peers = [
            makePeer(id: "macos", operatingSystem: "macOS"),
            makePeer(id: "windows", operatingSystem: "windows"),
            makePeer(id: "linux", operatingSystem: "linux"),
        ]

        XCTAssertEqual(
            TailscalePeerVisibility.filteredPeers(
                peers,
                showsOtherOperatingSystems: true
            ),
            peers
        )
    }

    func testVideoNetworkPathRequiresAnActivePeerAndPrioritizesCurrentRoute() {
        XCTAssertEqual(
            EmbeddedTailscaleRuntime.videoNetworkPath(
                isActive: false,
                currentAddress: "192.0.2.1:1234",
                peerRelay: "peer-relay",
                relay: "7"
            ),
            .tailscaleUnknown
        )
        XCTAssertEqual(
            EmbeddedTailscaleRuntime.videoNetworkPath(
                isActive: true,
                currentAddress: "192.0.2.1:1234",
                peerRelay: "peer-relay",
                relay: "7"
            ),
            .tailscaleDirect
        )
        XCTAssertEqual(
            EmbeddedTailscaleRuntime.videoNetworkPath(
                isActive: true,
                currentAddress: "  ",
                peerRelay: "peer-relay",
                relay: "7"
            ),
            .tailscalePeerRelay
        )
        XCTAssertEqual(
            EmbeddedTailscaleRuntime.videoNetworkPath(
                isActive: true,
                currentAddress: nil,
                peerRelay: "",
                relay: "7"
            ),
            .tailscaleDERP
        )
        XCTAssertEqual(
            EmbeddedTailscaleRuntime.videoNetworkPath(
                isActive: true,
                currentAddress: nil,
                peerRelay: nil,
                relay: "\n"
            ),
            .tailscaleUnknown
        )
    }

    private func makePeer(id: String, operatingSystem: String?) -> TailscalePeer {
        TailscalePeer(
            id: id,
            name: id,
            dnsName: "\(id).example.ts.net",
            addresses: ["100.64.0.10"],
            isOnline: true,
            operatingSystem: operatingSystem
        )
    }
}

private actor MockEmbeddedTailscaleRuntime: EmbeddedTailscaleRunning {
    private let initialEvents: [EmbeddedTailscaleEvent]
    private let loginError: Error?
    private let logoutError: Error?
    private var continuation: AsyncStream<EmbeddedTailscaleEvent>.Continuation?
    private(set) var didStart = false
    private(set) var loginCount = 0
    private(set) var logoutCount = 0

    init(
        events: [EmbeddedTailscaleEvent] = [],
        loginError: Error? = nil,
        logoutError: Error? = nil
    ) {
        initialEvents = events
        self.loginError = loginError
        self.logoutError = logoutError
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

    func logout() throws {
        logoutCount += 1
        if let logoutError { throw logoutError }
    }

    func send(_ event: EmbeddedTailscaleEvent) {
        continuation?.yield(event)
    }
}

private struct TestError: LocalizedError {
    var errorDescription: String? { "Test login failed" }
}
