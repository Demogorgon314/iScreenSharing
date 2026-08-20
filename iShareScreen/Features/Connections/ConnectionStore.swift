import Combine
import Foundation

@MainActor
final class ConnectionStore: ObservableObject {
    @Published private(set) var connections: [SavedConnection]

    private let defaults: UserDefaults
    private let storageKey: String

    init(defaults: UserDefaults = .standard, storageKey: String = "savedConnections") {
        self.defaults = defaults
        self.storageKey = storageKey
        connections = Self.load(defaults: defaults, key: storageKey)
    }

    func record(_ endpoint: ConnectionEndpoint, at date: Date = .now) {
        if let index = connections.firstIndex(where: { $0.endpoint == endpoint }) {
            connections[index].lastConnectedAt = date
        } else {
            connections.append(SavedConnection(endpoint: endpoint, lastConnectedAt: date))
        }
        connections.sort { $0.lastConnectedAt > $1.lastConnectedAt }
        persist()
    }

    func delete(_ connection: SavedConnection) {
        connections.removeAll { $0.id == connection.id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func load(defaults: UserDefaults, key: String) -> [SavedConnection] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SavedConnection].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.lastConnectedAt > $1.lastConnectedAt }
    }
}
