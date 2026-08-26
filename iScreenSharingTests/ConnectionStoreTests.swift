import XCTest
@testable import iScreenSharing

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

        store.record(endpoint, preferredUsername: "editor", at: firstDate)
        store.record(endpoint, preferredUsername: "editor", at: updatedDate)

        XCTAssertEqual(store.connections.count, 1)
        XCTAssertEqual(store.connections[0].lastConnectedAt, updatedDate)
        XCTAssertEqual(store.connections[0].preferredUsername, "editor")
        XCTAssertEqual(store.recentConnections.count, 1)
        XCTAssertEqual(store.recentConnections[0].endpoint, endpoint)
        XCTAssertEqual(store.recentConnections[0].lastConnectedAt, updatedDate)
        let restored = ConnectionStore(defaults: defaults)
        XCTAssertEqual(restored.connections, store.connections)
        XCTAssertEqual(restored.recentConnections, store.recentConnections)
    }

    func testLibraryCollectionsExcludeTailscaleConnections() throws {
        let direct = try ConnectionEndpoint(host: "192.168.1.10", route: .direct)
        let tailscale = try ConnectionEndpoint(host: "100.64.0.10", route: .tailscale)
        let store = ConnectionStore(defaults: defaults)

        store.record(direct, at: Date(timeIntervalSince1970: 100))
        store.record(tailscale, at: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(store.connections.count, 2)
        XCTAssertEqual(store.libraryConnections.map(\.endpoint), [direct])
        XCTAssertEqual(store.libraryRecentConnections.map(\.endpoint), [direct])
    }

    func testRecognizesOfficialTailscaleAddressRangesAtStartup() {
        XCTAssertTrue(TailscaleIPAddress.contains("100.64.0.0"))
        XCTAssertTrue(TailscaleIPAddress.contains("100.127.255.255"))
        XCTAssertFalse(TailscaleIPAddress.contains("100.128.0.0"))
        XCTAssertFalse(TailscaleIPAddress.contains("100.115.92.1"))
        XCTAssertTrue(TailscaleIPAddress.contains("fd7a:115c:a1e0::1"))
        XCTAssertFalse(TailscaleIPAddress.contains("fd7a:115c:a1e1::1"))
        XCTAssertFalse(TailscaleIPAddress.contains("deepdreams-mac-mini.tail.example.ts.net"))
    }

    func testPersistsDeviceInfoAndKeepsItWhenConnectionIsRecordedAgain() throws {
        let endpoint = try ConnectionEndpoint("example.local")
        let info = AppleRemoteDeviceInfo(
            modelIdentifier: "Mac16,10",
            deviceColor: "0",
            flags: 1
        )
        let store = ConnectionStore(defaults: defaults)

        store.record(endpoint, deviceInfo: info, at: Date(timeIntervalSince1970: 100))
        store.record(endpoint, preferredUsername: "editor", at: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(store.connection(for: endpoint)?.deviceInfo, info)
        XCTAssertEqual(ConnectionStore(defaults: defaults).connection(for: endpoint)?.deviceInfo, info)
    }

    func testUpdatesDeviceInfoOnlyForExistingConnections() throws {
        let endpoint = try ConnectionEndpoint("example.local")
        let unknownEndpoint = try ConnectionEndpoint("unknown.local")
        let info = AppleRemoteDeviceInfo(modelIdentifier: "Mac15,6", deviceColor: "1")
        let store = ConnectionStore(defaults: defaults)
        store.record(endpoint)

        store.updateDeviceInfo(info, for: endpoint)
        store.updateDeviceInfo(info, for: unknownEndpoint)

        XCTAssertEqual(store.connection(for: endpoint)?.deviceInfo, info)
        XCTAssertNil(store.connection(for: unknownEndpoint))
        XCTAssertEqual(store.connections.count, 1)
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

    func testUpdatesConnectionSettingsAndRejectsDuplicateEndpoint() throws {
        let store = ConnectionStore(defaults: defaults)
        store.record(try ConnectionEndpoint("one.local"))
        store.record(try ConnectionEndpoint("two.local"))
        let connection = try XCTUnwrap(store.connection(for: ConnectionEndpoint("one.local")))
        let updatedEndpoint = try ConnectionEndpoint("updated.local:5901")

        try store.update(
            connection,
            name: "  Studio Mac  ",
            endpoint: updatedEndpoint,
            preferredUsername: "  editor  ",
            sharingType: .highPerformance,
            virtualDisplayCount: .two
        )

        let updated = try XCTUnwrap(store.connection(for: updatedEndpoint))
        XCTAssertEqual(updated.name, "Studio Mac")
        XCTAssertEqual(updated.preferredUsername, "editor")
        XCTAssertEqual(updated.virtualDisplayCount, .two)
        XCTAssertEqual(ConnectionStore(defaults: defaults).connection(for: updatedEndpoint), updated)
        XCTAssertThrowsError(
            try store.update(
                updated,
                name: updated.name,
                endpoint: ConnectionEndpoint("two.local"),
                preferredUsername: updated.preferredUsername,
                sharingType: updated.sharingType,
                virtualDisplayCount: updated.virtualDisplayCount
            )
        ) {
            XCTAssertEqual($0 as? ConnectionStoreError, .duplicateEndpoint)
        }
    }

    func testLoadsLegacyConnectionsWithNativeDefaults() throws {
        let endpoint = try ConnectionEndpoint("legacy.local")
        let legacy = LegacySavedConnection(
            id: UUID(),
            endpoint: endpoint,
            name: "Legacy",
            lastConnectedAt: Date(timeIntervalSince1970: 100)
        )
        defaults.set(try JSONEncoder().encode([legacy]), forKey: "savedConnections")

        let connection = try XCTUnwrap(ConnectionStore(defaults: defaults).connections.first)

        XCTAssertEqual(connection.preferredUsername, "")
        XCTAssertEqual(connection.sharingType, .highPerformance)
        XCTAssertEqual(connection.virtualDisplayCount, .one)
        XCTAssertNil(connection.deviceInfo)
    }
}

private struct LegacySavedConnection: Codable {
    let id: UUID
    let endpoint: ConnectionEndpoint
    let name: String
    let lastConnectedAt: Date
}
