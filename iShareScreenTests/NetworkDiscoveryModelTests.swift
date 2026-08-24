import XCTest
@testable import iShareScreen

@MainActor
final class NetworkDiscoveryModelTests: XCTestCase {
    func testPublishesBrowserResults() async throws {
        let endpoint = ConnectionEndpoint(
            bonjourService: try BonjourServiceEndpoint(name: "Shared Mac")
        )
        let model = NetworkDiscoveryModel(
            browser: MockBonjourBrowser(updates: [.searching, .results([endpoint])]),
            deviceInfoResolver: MockBonjourDeviceInfoResolver()
        )

        await model.browse()

        XCTAssertEqual(
            model.state,
            .results([DiscoveredScreenSharingService(endpoint: endpoint, deviceInfo: nil)])
        )
    }

    func testPublishesResolvedDeviceInfo() async throws {
        let endpoint = ConnectionEndpoint(
            bonjourService: try BonjourServiceEndpoint(name: "Shared Mac")
        )
        let info = AppleRemoteDeviceInfo(modelIdentifier: "Mac16,10", deviceColor: "0")
        let model = NetworkDiscoveryModel(
            browser: MockBonjourBrowser(updates: [.results([endpoint])]),
            deviceInfoResolver: MockBonjourDeviceInfoResolver(info: info)
        )

        await model.browse()
        for _ in 0..<100 where model.state != .results([
            DiscoveredScreenSharingService(endpoint: endpoint, deviceInfo: info)
        ]) {
            await Task.yield()
        }

        XCTAssertEqual(
            model.state,
            .results([DiscoveredScreenSharingService(endpoint: endpoint, deviceInfo: info)])
        )
    }

    func testPublishesBrowserFailure() async {
        let model = NetworkDiscoveryModel(
            browser: MockBonjourBrowser(updates: [.failed("Local Network unavailable")])
        )

        await model.browse()

        XCTAssertEqual(model.state, .failed("Local Network unavailable"))
    }
}

private struct MockBonjourDeviceInfoResolver: BonjourDeviceInfoResolving {
    var info: AppleRemoteDeviceInfo?

    init(info: AppleRemoteDeviceInfo? = nil) {
        self.info = info
    }

    func deviceInfo(for endpoint: ConnectionEndpoint) async -> AppleRemoteDeviceInfo? {
        info
    }
}

private struct MockBonjourBrowser: BonjourBrowsing {
    let values: [BonjourBrowseUpdate]

    init(updates: [BonjourBrowseUpdate]) {
        values = updates
    }

    func updates() -> AsyncStream<BonjourBrowseUpdate> {
        AsyncStream { continuation in
            for value in values { continuation.yield(value) }
            continuation.finish()
        }
    }
}
