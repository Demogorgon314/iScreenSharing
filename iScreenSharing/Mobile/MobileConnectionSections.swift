import Foundation

/// History supplies ordering; saved configuration supplies current names and
/// device metadata. Never present a save-only operation as a recent connection.
struct MobileConnectionSections {
    let recent: [SavedConnection]
    let saved: [SavedConnection]

    init(saved: [SavedConnection], recent: [SavedConnection], query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ connection: SavedConnection) -> Bool {
            query.isEmpty || connection.name.localizedStandardContains(query)
                || connection.endpoint.displayName.localizedStandardContains(query)
        }
        var seen = Set<ConnectionEndpoint>()
        var history = [SavedConnection]()
        for entry in recent.sorted(by: { $0.lastConnectedAt > $1.lastConnectedAt }) {
            guard seen.insert(entry.endpoint).inserted else { continue }
            var current = saved.first(where: { $0.endpoint == entry.endpoint }) ?? entry
            current.lastConnectedAt = entry.lastConnectedAt
            if matches(current) { history.append(current) }
        }
        self.recent = history
        self.saved = saved.filter { !seen.contains($0.endpoint) && matches($0) }
    }
}
