import Foundation

struct ConnectionGroup: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var connectionIDs: Set<SavedConnection.ID>

    init(
        id: UUID = UUID(),
        name: String,
        connectionIDs: Set<SavedConnection.ID> = []
    ) {
        self.id = id
        self.name = name
        self.connectionIDs = connectionIDs
    }
}
