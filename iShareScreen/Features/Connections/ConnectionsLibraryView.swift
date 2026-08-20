import SwiftUI

struct ConnectionsLibraryView: View {
    private enum SidebarItem: Hashable {
        case allConnections
        case network
    }

    @ObservedObject var store: ConnectionStore
    @StateObject private var discovery: NetworkDiscoveryModel
    @Environment(\.openWindow) private var openWindow
    @State private var sidebarSelection: SidebarItem? = .allConnections
    @State private var selectedConnection: SavedConnection.ID?
    @State private var layout: ConnectionLibraryLayout = .list
    @State private var searchText = ""
    @State private var discoveryAttempt = 0

    init(store: ConnectionStore, browser: any BonjourBrowsing = BonjourBrowser()) {
        self.store = store
        _discovery = StateObject(wrappedValue: NetworkDiscoveryModel(browser: browser))
    }

    private var filteredConnections: [SavedConnection] {
        guard !searchText.isEmpty else { return store.connections }
        return store.connections.filter {
            $0.name.localizedStandardContains(searchText)
                || $0.endpoint.displayName.localizedStandardContains(searchText)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $sidebarSelection) {
                Label("All Connections", systemImage: "rectangle.on.rectangle")
                    .tag(SidebarItem.allConnections)
                Label("Network", systemImage: "network")
                    .tag(SidebarItem.network)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 16) {
                    Button {
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .help("New Group")

                    Button {
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.plain)
                    .disabled(true)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(.bar)
            }
        } detail: {
            Group {
                if sidebarSelection == .network {
                    networkContent
                } else if filteredConnections.isEmpty {
                    ContentUnavailableView {
                        Label("No Connections", systemImage: "display")
                    } description: {
                        Text("Create a connection to start sharing another Mac’s screen.")
                    } actions: {
                        Button("New Connection…") {
                            openWindow(id: "new-connection")
                        }
                    }
                } else if layout == .list {
                    connectionList
                } else {
                    connectionGrid
                }
            }
            .navigationTitle(sidebarSelection == .network ? "Network" : "All Connections")
        }
        .focusedSceneValue(\.connectionLibraryLayout, $layout)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Show connections as icons, or in a list", selection: $layout) {
                    Image(systemName: "rectangle.grid.2x2").tag(ConnectionLibraryLayout.icons)
                    Image(systemName: "list.bullet").tag(ConnectionLibraryLayout.list)
                }
                .pickerStyle(.segmented)
                .fixedSize()

                Menu {
                    Button("Remove Connection", role: .destructive) {
                        deleteSelectedConnection()
                    }
                    .disabled(selectedConnection == nil)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }

                Button {
                    openWindow(id: "new-connection")
                } label: {
                    Label("New Connection", systemImage: "plus")
                }
            }
        }
    }

    private var networkContent: some View {
        ZStack {
            switch discovery.state {
            case .searching:
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Looking for Macs…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .results(let endpoints) where endpoints.isEmpty:
                ContentUnavailableView(
                    "No Macs Found",
                    systemImage: "network.slash",
                    description: Text("Macs advertising Screen Sharing on your local network will appear here.")
                )
            case .results(let endpoints):
                List(endpoints, id: \.self) { endpoint in
                    NetworkConnectionRow(endpoint: endpoint)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            openWindow(id: "authentication", value: endpoint)
                        }
                        .contextMenu {
                            Button("Connect") {
                                openWindow(id: "authentication", value: endpoint)
                            }
                        }
                }
                .listStyle(.inset)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Can’t Browse Network", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { discoveryAttempt += 1 }
                }
            }
        }
        .task(id: discoveryAttempt) {
            await discovery.browse()
        }
    }

    private var connectionList: some View {
        List(filteredConnections, selection: $selectedConnection) { connection in
            ConnectionRow(connection: connection)
                .tag(connection.id)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    openWindow(value: connection.endpoint)
                }
                .contextMenu {
                    Button("Connect") {
                        openWindow(value: connection.endpoint)
                    }
                    Button("Remove", role: .destructive) {
                        store.delete(connection)
                    }
                }
        }
        .listStyle(.inset)
    }

    private var connectionGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 18)], spacing: 24) {
                ForEach(filteredConnections) { connection in
                    VStack(spacing: 8) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 46, weight: .light))
                            .symbolRenderingMode(.hierarchical)
                        Text(connection.name)
                            .lineLimit(1)
                        Text(connection.endpoint.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(10)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        openWindow(value: connection.endpoint)
                    }
                }
            }
            .padding(24)
        }
    }

    private func deleteSelectedConnection() {
        guard let selectedConnection,
              let connection = store.connections.first(where: { $0.id == selectedConnection }) else {
            return
        }
        store.delete(connection)
        self.selectedConnection = nil
    }
}

private struct NetworkConnectionRow: View {
    let endpoint: ConnectionEndpoint

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(endpoint.displayName)
                Text(serviceDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var serviceDescription: String {
        guard let service = endpoint.bonjourService else { return endpoint.displayName }
        let domain = service.domain.hasSuffix(".") ? String(service.domain.dropLast()) : service.domain
        return "\(service.name).\(service.type).\(domain)"
    }
}

private struct ConnectionRow: View {
    let connection: SavedConnection

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name)
                    .font(.body.weight(.medium))
                Text(connection.endpoint.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(connection.lastConnectedAt, format: .dateTime.month().day().year().hour().minute())
                .foregroundStyle(.secondary)
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 7)
    }
}
