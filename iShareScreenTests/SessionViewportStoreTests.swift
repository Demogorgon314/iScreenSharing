import XCTest
@testable import iShareScreen

final class SessionViewportStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SessionViewportStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSavesViewportSeparatelyForEachEndpoint() throws {
        let first = try ConnectionEndpoint("first.local")
        let second = try ConnectionEndpoint("second.local")
        let store = SessionViewportStore(defaults: defaults)

        store.save(CGSize(width: 1234, height: 678), for: first)

        XCTAssertEqual(store.size(for: first), CGSize(width: 1234, height: 678))
        XCTAssertNil(store.size(for: second))
    }

    func testIgnoresInvalidViewport() throws {
        let endpoint = try ConnectionEndpoint("example.local")
        let store = SessionViewportStore(defaults: defaults)

        store.save(.zero, for: endpoint)

        XCTAssertNil(store.size(for: endpoint))
    }
}
