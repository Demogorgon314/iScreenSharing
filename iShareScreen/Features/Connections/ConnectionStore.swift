import Combine
import Foundation

@MainActor
final class ConnectionStore: ObservableObject {
    @Published private(set) var connections: [SavedConnection]
    @Published private(set) var recentConnections: [SavedConnection]

    private let defaults: UserDefaults
    private let storageKey: String
    private let recentStorageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "savedConnections",
        recentStorageKey: String = "recentConnections"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.recentStorageKey = recentStorageKey
        connections = Self.load(defaults: defaults, key: storageKey)
        recentConnections = Self.load(defaults: defaults, key: recentStorageKey)
    }

    func record(_ endpoint: ConnectionEndpoint, at date: Date = .now) {
        Self.record(endpoint, at: date, in: &connections)
        Self.record(endpoint, at: date, in: &recentConnections)
        persist()
    }

    func delete(_ connection: SavedConnection) {
        connections.removeAll { $0.id == connection.id }
        persist()
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
}
