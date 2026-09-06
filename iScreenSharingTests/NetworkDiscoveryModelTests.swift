import struct ScreenSharingProtocol.AppleRemoteDeviceInfo
import XCTest
@testable import iScreenSharing

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

    func testSupersededBrowseCannotOverwriteFreshResults() async throws {
        let old = AsyncStream<BonjourBrowseUpdate>.makeStream()
        let fresh = AsyncStream<BonjourBrowseUpdate>.makeStream()
        let started = expectation(description: "Old browser started")
        let restarted = expectation(description: "Fresh browser started")
        let browser = RestartableBonjourBrowser(streams: [old.stream, fresh.stream], started: [started, restarted])
        let model = NetworkDiscoveryModel(browser: browser, deviceInfoResolver: MockBonjourDeviceInfoResolver())
        let first = Task { await model.browse() }
        await fulfillment(of: [started], timeout: 2)
        let second = Task { await model.browse() }
        await fulfillment(of: [restarted], timeout: 2)
        let endpoint = ConnectionEndpoint(bonjourService: try BonjourServiceEndpoint(name: "Fresh Mac"))
        fresh.continuation.yield(.results([endpoint]))
        fresh.continuation.finish()
        await second.value
        old.continuation.yield(.failed("Defunct Connection"))
        old.continuation.finish()
        await first.value
        XCTAssertEqual(model.state, .results([DiscoveredScreenSharingService(endpoint: endpoint, deviceInfo: nil)]))
    }

    func testCancelledBrowseTerminatesStreamAndCanRestart() async {
        let old = AsyncStream<BonjourBrowseUpdate>.makeStream()
        let fresh = AsyncStream<BonjourBrowseUpdate>.makeStream()
        let started = expectation(description: "Browser started")
        let restarted = expectation(description: "Browser restarted")
        let terminated = expectation(description: "Old stream terminated")
        old.continuation.onTermination = { _ in terminated.fulfill() }
        let browser = RestartableBonjourBrowser(streams: [old.stream, fresh.stream], started: [started, restarted])
        let model = NetworkDiscoveryModel(browser: browser, deviceInfoResolver: MockBonjourDeviceInfoResolver())
        let first = Task { await model.browse() }
        await fulfillment(of: [started], timeout: 2)
        first.cancel()
        await first.value
        await fulfillment(of: [terminated], timeout: 2)
        let second = Task { await model.browse() }
        await fulfillment(of: [restarted], timeout: 2)
        old.continuation.yield(.failed("Defunct Connection"))
        fresh.continuation.yield(.results([]))
        fresh.continuation.finish()
        await second.value
        XCTAssertEqual(model.state, .results([]))
    }

    func testAlreadyCancelledBrowseDoesNotClearFailure() async {
        let model = NetworkDiscoveryModel(browser: MockBonjourBrowser(updates: [.failed("Defunct Connection")]))
        await model.browse()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await model.browse()
        }
        await task.value
        XCTAssertEqual(model.state, .failed("Defunct Connection"))
    }
}

private final class RestartableBonjourBrowser: BonjourBrowsing, @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [AsyncStream<BonjourBrowseUpdate>]
    private var started: [XCTestExpectation]

    init(streams: [AsyncStream<BonjourBrowseUpdate>], started: [XCTestExpectation]) {
        self.streams = streams
        self.started = started
    }

    func updates() -> AsyncStream<BonjourBrowseUpdate> {
        lock.lock()
        defer { lock.unlock() }
        let stream = streams.removeFirst()
        started.removeFirst().fulfill()
        return stream
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
