import Combine
import Darwin
import Foundation

@MainActor
final class ConnectionStore: ObservableObject {
    @Published private(set) var connections: [SavedConnection]
    @Published private(set) var recentConnections: [SavedConnection]
    @Published private(set) var groups: [ConnectionGroup]

    private let defaults: UserDefaults
    private let storageKey: String
    private let recentStorageKey: String
    private let groupStorageKey: String

    var libraryConnections: [SavedConnection] {
        connections.filter {
            $0.endpoint.route == .direct && !TailscaleIPAddress.contains($0.endpoint.host)
        }
    }

    var libraryRecentConnections: [SavedConnection] {
        recentConnections.filter {
            $0.endpoint.route == .direct && !TailscaleIPAddress.contains($0.endpoint.host)
        }
    }

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "savedConnections",
        recentStorageKey: String = "recentConnections",
        groupStorageKey: String = "connectionGroups"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.recentStorageKey = recentStorageKey
        self.groupStorageKey = groupStorageKey
        connections = Self.load(defaults: defaults, key: storageKey)
        recentConnections = Self.load(defaults: defaults, key: recentStorageKey)
        groups = Self.load(defaults: defaults, key: groupStorageKey)
    }

    func record(
        _ endpoint: ConnectionEndpoint,
        preferredUsername: String? = nil,
        standardQuality: StandardRFBQuality? = nil,
        deviceInfo: AppleRemoteDeviceInfo? = nil,
        at date: Date = .now
    ) {
        Self.record(
            endpoint,
            standardQuality: standardQuality,
            deviceInfo: deviceInfo,
            at: date,
            in: &connections
        )
        Self.record(
            endpoint,
            standardQuality: standardQuality,
            deviceInfo: deviceInfo,
            at: date,
            in: &recentConnections
        )
        if let preferredUsername,
           let index = connections.firstIndex(where: { $0.endpoint == endpoint }) {
            connections[index].preferredUsername = preferredUsername
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        persist()
    }

    func updateDeviceInfo(_ deviceInfo: AppleRemoteDeviceInfo, for endpoint: ConnectionEndpoint) {
        let connectionUpdated = Self.updateDeviceInfo(deviceInfo, for: endpoint, in: &connections)
        let recentUpdated = Self.updateDeviceInfo(deviceInfo, for: endpoint, in: &recentConnections)
        guard connectionUpdated || recentUpdated else { return }
        persist()
    }

    func updateStandardQuality(_ quality: StandardRFBQuality, for endpoint: ConnectionEndpoint) {
        let connectionUpdated = Self.updateStandardQuality(quality, for: endpoint, in: &connections)
        let recentUpdated = Self.updateStandardQuality(
            quality,
            for: endpoint,
            in: &recentConnections
        )
        guard connectionUpdated || recentUpdated else { return }
        persist()
    }

    func delete(_ connection: SavedConnection) {
        connections.removeAll { $0.id == connection.id }
        for index in groups.indices {
            groups[index].connectionIDs.remove(connection.id)
        }
        persist()
    }

    func connection(for endpoint: ConnectionEndpoint) -> SavedConnection? {
        connections.first { $0.endpoint == endpoint }
    }

    func networkConfiguration(
        for endpoint: ConnectionEndpoint,
        deviceInfo: AppleRemoteDeviceInfo?
    ) -> SavedConnection {
        if let index = connections.firstIndex(where: { $0.endpoint == endpoint }) {
            if connections[index].deviceInfo == nil, let deviceInfo {
                connections[index].deviceInfo = deviceInfo
                persist()
            }
            return connections[index]
        }

        let connection = SavedConnection(
            endpoint: endpoint,
            name: endpoint.displayName,
            deviceInfo: deviceInfo
        )
        connections.append(connection)
        connections.sort { $0.lastConnectedAt > $1.lastConnectedAt }
        persist()
        return connection
    }

    func tailscaleConfiguration(
        for endpoint: ConnectionEndpoint,
        name: String,
        deviceInfo: AppleRemoteDeviceInfo?
    ) -> SavedConnection {
        if let index = connections.firstIndex(where: { $0.endpoint == endpoint }) {
            var didChange = false
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, connections[index].name != name {
                connections[index].name = name
                didChange = true
            }
            if connections[index].deviceInfo == nil, let deviceInfo {
                connections[index].deviceInfo = deviceInfo
                didChange = true
            }
            if didChange { persist() }
            return connections[index]
        }

        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let connection = SavedConnection(
            endpoint: endpoint,
            name: name.isEmpty ? endpoint.displayName : name,
            deviceInfo: deviceInfo
        )
        connections.append(connection)
        connections.sort { $0.lastConnectedAt > $1.lastConnectedAt }
        persist()
        return connection
    }

    func update(
        _ connection: SavedConnection,
        name: String,
        endpoint: ConnectionEndpoint,
        preferredUsername: String,
        sharingType: ScreenSharingType,
        standardQuality: StandardRFBQuality = .high,
        virtualDisplayCount: VirtualDisplayCount
    ) throws {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else {
            throw ConnectionStoreError.connectionNotFound
        }
        guard !connections.contains(where: { $0.id != connection.id && $0.endpoint == endpoint }) else {
            throw ConnectionStoreError.duplicateEndpoint
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ConnectionStoreError.emptyName }

        connections[index].name = name
        connections[index].endpoint = endpoint
        connections[index].preferredUsername = preferredUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        connections[index].sharingType = sharingType
        connections[index].standardQuality = standardQuality
        connections[index].virtualDisplayCount = virtualDisplayCount
        persist()
    }

    @discardableResult
    func createGroup(including connection: SavedConnection? = nil) -> ConnectionGroup {
        let group = ConnectionGroup(
            name: uniqueGroupName(),
            connectionIDs: Set(connection.map { [$0.id] } ?? [])
        )
        groups.append(group)
        persist()
        return group
    }

    func rename(_ group: ConnectionGroup, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].name = name
        persist()
    }

    func delete(_ group: ConnectionGroup) {
        groups.removeAll { $0.id == group.id }
        persist()
    }

    func add(_ connection: SavedConnection, to group: ConnectionGroup) {
        guard connections.contains(where: { $0.id == connection.id }),
              let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].connectionIDs.insert(connection.id)
        persist()
    }

    func connections(in group: ConnectionGroup) -> [SavedConnection] {
        connections.filter { group.connectionIDs.contains($0.id) }
    }

    func clearRecentConnections() {
        recentConnections.removeAll(keepingCapacity: false)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(connections) {
            defaults.set(data, forKey: storageKey)
        }
        if let data = try? JSONEncoder().encode(recentConnections) {
            defaults.set(data, forKey: recentStorageKey)
        }
        if let data = try? JSONEncoder().encode(groups) {
            defaults.set(data, forKey: groupStorageKey)
        }
    }

    private func uniqueGroupName() -> String {
        let baseName = "Untitled Group"
        let names = Set(groups.map(\.name))
        guard names.contains(baseName) else { return baseName }
        var suffix = 2
        while names.contains("\(baseName) \(suffix)") {
            suffix += 1
        }
        return "\(baseName) \(suffix)"
    }

    private static func record(
        _ endpoint: ConnectionEndpoint,
        standardQuality: StandardRFBQuality?,
        deviceInfo: AppleRemoteDeviceInfo?,
        at date: Date,
        in connections: inout [SavedConnection]
    ) {
        if let index = connections.firstIndex(where: { $0.endpoint == endpoint }) {
            connections[index].lastConnectedAt = date
            if let deviceInfo {
                connections[index].deviceInfo = deviceInfo
            }
            if let standardQuality {
                connections[index].standardQuality = standardQuality
            }
        } else {
            connections.append(SavedConnection(
                endpoint: endpoint,
                lastConnectedAt: date,
                standardQuality: standardQuality ?? .high,
                deviceInfo: deviceInfo
            ))
        }
        connections.sort { $0.lastConnectedAt > $1.lastConnectedAt }
    }

    private static func updateDeviceInfo(
        _ deviceInfo: AppleRemoteDeviceInfo,
        for endpoint: ConnectionEndpoint,
        in connections: inout [SavedConnection]
    ) -> Bool {
        guard let index = connections.firstIndex(where: { $0.endpoint == endpoint }),
              connections[index].deviceInfo != deviceInfo else { return false }
        connections[index].deviceInfo = deviceInfo
        return true
    }

    private static func updateStandardQuality(
        _ quality: StandardRFBQuality,
        for endpoint: ConnectionEndpoint,
        in connections: inout [SavedConnection]
    ) -> Bool {
        guard let index = connections.firstIndex(where: { $0.endpoint == endpoint }),
              connections[index].standardQuality != quality else { return false }
        connections[index].standardQuality = quality
        return true
    }

    private static func load(defaults: UserDefaults, key: String) -> [SavedConnection] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SavedConnection].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.lastConnectedAt > $1.lastConnectedAt }
    }

    private static func load(defaults: UserDefaults, key: String) -> [ConnectionGroup] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ConnectionGroup].self, from: data) else {
            return []
        }
        return decoded
    }
}

enum TailscaleIPAddress {
    static func contains(_ host: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            let address = UInt32(bigEndian: ipv4.s_addr)
            let isCGNAT = address & 0xffc0_0000 == 0x6440_0000
            let isChromeOSVM = address & 0xffff_fe00 == 0x6473_5c00
            return isCGNAT && !isChromeOSVM
        }

        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, host, &ipv6) == 1 else { return false }
        return withUnsafeBytes(of: &ipv6) { bytes in
            bytes.starts(with: [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0])
        }
    }
}

enum ConnectionStoreError: LocalizedError, Equatable {
    case connectionNotFound
    case duplicateEndpoint
    case emptyName

    var errorDescription: String? {
        switch self {
        case .connectionNotFound: "The saved connection no longer exists."
        case .duplicateEndpoint: "A connection for this server address and port already exists."
        case .emptyName: "Enter a name for this connection."
        }
    }
}
