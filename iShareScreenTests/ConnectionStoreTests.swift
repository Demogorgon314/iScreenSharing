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

    func testCreatesRenamesAndPersistsGroups() throws {
        let store = ConnectionStore(defaults: defaults)
        let first = store.createGroup()
        let second = store.createGroup()

        store.rename(first, to: "  Work Macs  ")
        store.rename(second, to: "   ")

        XCTAssertEqual(store.groups.map(\.name), ["Work Macs", "Untitled Group 2"])
        XCTAssertEqual(ConnectionStore(defaults: defaults).groups, store.groups)
    }

    func testMaintainsGroupMembershipWithoutDeletingConnections() throws {
        let store = ConnectionStore(defaults: defaults)
        store.record(try ConnectionEndpoint("one.local"), at: Date(timeIntervalSince1970: 100))
        store.record(try ConnectionEndpoint("two.local"), at: Date(timeIntervalSince1970: 200))
        let firstConnection = try XCTUnwrap(store.connections.first { $0.endpoint.host == "one.local" })
        let secondConnection = try XCTUnwrap(store.connections.first { $0.endpoint.host == "two.local" })
        let group = store.createGroup(including: firstConnection)

        store.add(secondConnection, to: group)

        let updatedGroup = try XCTUnwrap(store.groups.first)
        XCTAssertEqual(Set(store.connections(in: updatedGroup).map(\.id)), [firstConnection.id, secondConnection.id])
        store.delete(firstConnection)
        let groupAfterConnectionDeletion = try XCTUnwrap(store.groups.first)
        XCTAssertEqual(groupAfterConnectionDeletion.connectionIDs, [secondConnection.id])

        store.delete(groupAfterConnectionDeletion)

        XCTAssertEqual(store.connections.count, 1)
        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertTrue(ConnectionStore(defaults: defaults).groups.isEmpty)
    }
}
