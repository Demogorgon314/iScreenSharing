import XCTest
@testable import iShareScreen

@MainActor
final class NetworkDiscoveryModelTests: XCTestCase {
    func testPublishesBrowserResults() async throws {
        let endpoint = ConnectionEndpoint(
            bonjourService: try BonjourServiceEndpoint(name: "Shared Mac")
        )
        let model = NetworkDiscoveryModel(
            browser: MockBonjourBrowser(updates: [.searching, .results([endpoint])])
        )

        await model.browse()

        XCTAssertEqual(model.state, .results([endpoint]))
    }

    func testPublishesBrowserFailure() async {
        let model = NetworkDiscoveryModel(
            browser: MockBonjourBrowser(updates: [.failed("Local Network unavailable")])
        )

        await model.browse()

        XCTAssertEqual(model.state, .failed("Local Network unavailable"))
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
