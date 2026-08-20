import Combine
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

    func record(_ endpoint: ConnectionEndpoint, at date: Date = .now) {
        Self.record(endpoint, at: date, in: &connections)
        Self.record(endpoint, at: date, in: &recentConnections)
        persist()
    }

    func delete(_ connection: SavedConnection) {
        connections.removeAll { $0.id == connection.id }
        for index in groups.indices {
            groups[index].connectionIDs.remove(connection.id)
        }
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
        at date: Date,
        in connections: inout [SavedConnection]
    ) {
        if let index = connections.firstIndex(where: { $0.endpoint == endpoint }) {
            connections[index].lastConnectedAt = date
        } else {
            connections.append(SavedConnection(endpoint: endpoint, lastConnectedAt: date))
        }
        connections.sort { $0.lastConnectedAt > $1.lastConnectedAt }
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
