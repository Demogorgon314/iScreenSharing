import Foundation

struct SavedConnection: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var endpoint: ConnectionEndpoint
    var name: String
    var lastConnectedAt: Date

    init(
        id: UUID = UUID(),
        endpoint: ConnectionEndpoint,
        name: String? = nil,
        lastConnectedAt: Date = .now
    ) {
        self.id = id
        self.endpoint = endpoint
        self.name = name ?? endpoint.displayName
        self.lastConnectedAt = lastConnectedAt
    }
}

