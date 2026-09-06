import XCTest
import struct ScreenSharingProtocol.AppleRemoteDeviceInfo
@testable import iScreenSharing

@MainActor
final class MobileConnectionDraftTests: XCTestCase {
    func testEditingEndpointClearsHardwareMetadataButRenamingPreservesIt() throws {
        let suite = "MobileConnectionDraftTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConnectionStore(defaults: defaults)
        let endpoint = try ConnectionEndpoint("first.local")
        let info = AppleRemoteDeviceInfo(modelIdentifier: "Mac16,10")
        let original = try MobileConnectionDraft(connection: SavedConnection(endpoint: endpoint, deviceInfo: info)).save(in: store)
        var draft = MobileConnectionDraft(connection: original)
        draft.name = "Renamed"
        let renamed = try draft.save(in: store, editing: original)
        XCTAssertEqual(renamed.deviceInfo, info)
        draft.address = "second.local"
        let moved = try draft.save(in: store, editing: renamed)
        XCTAssertEqual(moved.id, original.id)
        XCTAssertNil(moved.deviceInfo)
        XCTAssertNil(ConnectionStore(defaults: defaults).connection(for: moved.endpoint)?.deviceInfo)
    }

    func testSavingDiscoveredMacRetainsItsModelForOfflineIcon() throws {
        let suite = "MobileConnectionDraftTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let info = AppleRemoteDeviceInfo(modelIdentifier: "Mac16,10")
        let endpoint = ConnectionEndpoint(bonjourService: try BonjourServiceEndpoint(name: "Office Mac"))
        let draft = MobileConnectionDraft(connection: SavedConnection(endpoint: endpoint, deviceInfo: info))
        _ = try draft.save(in: ConnectionStore(defaults: defaults))
        XCTAssertEqual(ConnectionStore(defaults: defaults).connection(for: endpoint)?.deviceInfo, info)
    }

    func testSaveRestoresConfigurationWithoutRecordingAConnection() throws {
        let suite = "MobileConnectionDraftTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConnectionStore(defaults: defaults)
        var draft = MobileConnectionDraft(address: "192.0.2.10")
        draft.name = " Studio "
        draft.username = " editor "
        draft.port = "5901"
        let saved = try draft.save(in: store)
        let restored = ConnectionStore(defaults: defaults)
        XCTAssertEqual(restored.connections, [saved])
        XCTAssertEqual(saved.name, "Studio")
        XCTAssertEqual(saved.preferredUsername, "editor")
        XCTAssertEqual(saved.endpoint.port, 5901)
        XCTAssertEqual(saved.virtualDisplayCount, .one)
        XCTAssertTrue(restored.recentConnections.isEmpty)
        let date = Date(timeIntervalSince1970: 100)
        store.record(saved.endpoint, preferredUsername: "editor", at: date)
        XCTAssertEqual(store.recentConnections.first?.lastConnectedAt, date)
        XCTAssertEqual(store.connection(for: saved.endpoint)?.name, "Studio")
    }

    func testBonjourIdentitySurvivesRenameAndUsernameEdit() throws {
        let endpoint = ConnectionEndpoint(bonjourService: try BonjourServiceEndpoint(name: "Office Mac"))
        var draft = MobileConnectionDraft(connection: SavedConnection(endpoint: endpoint))
        draft.name = "My Mac"
        draft.username = "user"
        XCTAssertEqual(try draft.endpoint(), endpoint)
    }

    func testInvalidPortDoesNotSaveAndDuplicateEditPreservesOriginal() throws {
        let suite = "MobileConnectionDraftTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConnectionStore(defaults: defaults)
        var draft = MobileConnectionDraft(address: "first.local")
        for port in ["0", "65536", "abc", "-1", ""] {
            draft.port = port
            XCTAssertThrowsError(try draft.save(in: store))
            XCTAssertTrue(store.connections.isEmpty)
        }
        draft.port = "5900"
        let first = try draft.save(in: store)
        let second = try MobileConnectionDraft(address: "second.local").save(in: store)
        var edit = MobileConnectionDraft(connection: first)
        edit.address = second.endpoint.host
        XCTAssertThrowsError(try edit.save(in: store, editing: first))
        XCTAssertEqual(store.connection(for: first.endpoint), first)
    }

    func testURLPortAndDefaultNameRemainSupported() throws {
        let draft = MobileConnectionDraft(address: "vnc://192.0.2.10:5901")
        XCTAssertEqual(try draft.endpoint().port, 5901)
        XCTAssertThrowsError(try MobileConnectionDraft(address: "  ").endpoint())
    }
}
