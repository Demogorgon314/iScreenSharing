import XCTest
@testable import iShareScreen

@MainActor
final class ConnectionStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ConnectionStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testRecordsUpdatesAndPersistsConnections() throws {
        let endpoint = try ConnectionEndpoint("example.local")
        let firstDate = Date(timeIntervalSince1970: 100)
        let updatedDate = Date(timeIntervalSince1970: 200)
        let store = ConnectionStore(defaults: defaults)

        store.record(endpoint, at: firstDate)
        store.record(endpoint, at: updatedDate)

        XCTAssertEqual(store.connections.count, 1)
        XCTAssertEqual(store.connections[0].lastConnectedAt, updatedDate)
        XCTAssertEqual(store.recentConnections.count, 1)
        XCTAssertEqual(store.recentConnections[0].endpoint, endpoint)
        XCTAssertEqual(store.recentConnections[0].lastConnectedAt, updatedDate)
        let restored = ConnectionStore(defaults: defaults)
        XCTAssertEqual(restored.connections, store.connections)
        XCTAssertEqual(restored.recentConnections, store.recentConnections)
    }

    func testDeleteRemovesPersistedConnection() throws {
        let store = ConnectionStore(defaults: defaults)
        store.record(try ConnectionEndpoint("example.local"))

        store.delete(try XCTUnwrap(store.connections.first))

        XCTAssertTrue(store.connections.isEmpty)
        XCTAssertTrue(ConnectionStore(defaults: defaults).connections.isEmpty)
        XCTAssertEqual(store.recentConnections.count, 1)
    }

    func testClearsOnlyRecentConnections() throws {
        let store = ConnectionStore(defaults: defaults)
        store.record(try ConnectionEndpoint("example.local"))

        store.clearRecentConnections()

        XCTAssertEqual(store.connections.count, 1)
        XCTAssertTrue(store.recentConnections.isEmpty)
        XCTAssertTrue(ConnectionStore(defaults: defaults).recentConnections.isEmpty)
    }
}
