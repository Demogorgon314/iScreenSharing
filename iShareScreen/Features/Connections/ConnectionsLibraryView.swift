import SwiftUI

struct ConnectionsLibraryView: View {
    private enum SidebarItem: Hashable {
        case allConnections
        case network
        case group(ConnectionGroup.ID)
    }

    @ObservedObject var store: ConnectionStore
    @StateObject private var discovery: NetworkDiscoveryModel
    @Environment(\.openWindow) private var openWindow
    @State private var sidebarSelection: SidebarItem? = .allConnections
    @State private var selectedConnection: SavedConnection.ID?
    @State private var editingConnection: SavedConnection?
    @State private var layout: ConnectionLibraryLayout = .list
    @State private var searchText = ""
    @State private var discoveryAttempt = 0
    @State private var editingGroupID: ConnectionGroup.ID?
    @State private var groupNameDraft = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var groupNameFocused: Bool

    init(store: ConnectionStore, browser: any BonjourBrowsing = BonjourBrowser()) {
        self.store = store
        _discovery = StateObject(wrappedValue: NetworkDiscoveryModel(browser: browser))
    }

    private var filteredConnections: [SavedConnection] {
        let connections = selectedGroup.map(store.connections(in:)) ?? store.connections
        guard !searchText.isEmpty else { return connections }
        return connections.filter {
            $0.name.localizedStandardContains(searchText)
                || $0.endpoint.displayName.localizedStandardContains(searchText)
        }
    }

    private var selectedGroup: ConnectionGroup? {
        guard case .group(let id) = sidebarSelection else { return nil }
        return store.groups.first { $0.id == id }
    }

    private var detailTitle: String {
        if sidebarSelection == .network { return "Network" }
        return selectedGroup?.name ?? "All Connections"
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $sidebarSelection) {
                Label("All Connections", systemImage: "rectangle.on.rectangle")
                    .tag(SidebarItem.allConnections)
                Label("Network", systemImage: "network")
                    .tag(SidebarItem.network)
                ForEach(store.groups) { group in
                    groupSidebarRow(group)
                        .tag(SidebarItem.group(group.id))
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 16) {
                    Button {
                        createGroup()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .help("New Group")

                    Button {
                        deleteSelectedGroup()
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedGroup == nil)
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
            .navigationTitle(detailTitle)
        }
        .focusedSceneValue(\.connectionLibraryLayout, $layout)
        .focusedSceneValue(
            \.connectionLibraryActions,
            ConnectionLibraryActions(focusSearch: { searchFocused = true })
        )
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search")
        .searchFocused($searchFocused)
        .onOpenURL(perform: openConnection)
        .task(id: discoveryAttempt) {
            await discovery.browse()
        }
        .installsConnectionMenuTitle()
        .sheet(item: $editingConnection) { connection in
            ConnectionEditorView(connection: connection, store: store) { endpoint in
                openWindow(id: "authentication", value: endpoint)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Show connections as icons, or in a list", selection: $layout) {
                    Image(systemName: "rectangle.grid.2x2").tag(ConnectionLibraryLayout.icons)
                    Image(systemName: "list.bullet").tag(ConnectionLibraryLayout.list)
                }
                .pickerStyle(.segmented)
                .fixedSize()

                Menu {
                    Button("Connect") {
                        connectSelectedConnection()
                    }
                    .disabled(selectedConnection == nil)
                    Button("Edit") {
                        editSelectedConnection()
                    }
                    .disabled(selectedConnection == nil)
                    Button("Delete", role: .destructive) {
                        deleteSelectedConnection()
                    }
                    .disabled(selectedConnection == nil)
                    Divider()
                    Menu("Add to Existing Group") {
                        ForEach(store.groups) { group in
                            Button(group.name) { addSelectedConnection(to: group) }
                        }
                    }
                    .disabled(selectedConnection == nil || store.groups.isEmpty)
                    Button("Create New Group") {
                        createGroup(includingSelectedConnection: true)
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

    @ViewBuilder
    private func groupSidebarRow(_ group: ConnectionGroup) -> some View {
        if editingGroupID == group.id {
            TextField("Group Name", text: $groupNameDraft)
                .focused($groupNameFocused)
                .onSubmit { commitGroupName(group) }
                .onExitCommand { cancelGroupName() }
        } else {
            Text(group.name)
                .contextMenu {
                    Button("Rename") { beginRenaming(group) }
                    Button("Delete", role: .destructive) { delete(group) }
                }
                .onTapGesture(count: 2) { beginRenaming(group) }
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
                .alternatingRowBackgrounds()
                .environment(\.defaultMinListRowHeight, 50)
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
    }

    private var connectionList: some View {
        List(filteredConnections, selection: $selectedConnection) { connection in
            ConnectionRow(connection: connection) {
                editingConnection = connection
            }
                .tag(connection.id)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded {
                        selectedConnection = connection.id
                    }
                )
                .onTapGesture(count: 2) {
                    openWindow(id: "authentication", value: connection.endpoint)
                }
                .contextMenu {
                    Button("Connect") {
                        openWindow(id: "authentication", value: connection.endpoint)
                    }
                    Button("Edit") { editingConnection = connection }
                    Button("Remove", role: .destructive) {
                        store.delete(connection)
                    }
                }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        .environment(\.defaultMinListRowHeight, 50)
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
                    .onTapGesture {
                        selectedConnection = connection.id
                    }
                    .onTapGesture(count: 2) {
                        openWindow(id: "authentication", value: connection.endpoint)
                    }
                    .contextMenu {
                        Button("Connect") {
                            openWindow(id: "authentication", value: connection.endpoint)
                        }
                        Button("Edit") { editingConnection = connection }
                        Button("Delete", role: .destructive) { store.delete(connection) }
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

    private func connectSelectedConnection() {
        guard let connection = selectedSavedConnection else { return }
        openWindow(id: "authentication", value: connection.endpoint)
    }

    private func editSelectedConnection() {
        editingConnection = selectedSavedConnection
    }

    private func addSelectedConnection(to group: ConnectionGroup) {
        guard let connection = selectedSavedConnection else { return }
        store.add(connection, to: group)
    }

    private var selectedSavedConnection: SavedConnection? {
        guard let selectedConnection else { return nil }
        return store.connections.first { $0.id == selectedConnection }
    }

    private func createGroup(includingSelectedConnection: Bool = false) {
        let connection = includingSelectedConnection ? selectedSavedConnection : nil
        let group = store.createGroup(including: connection)
        sidebarSelection = .group(group.id)
        beginRenaming(group)
    }

    private func beginRenaming(_ group: ConnectionGroup) {
        editingGroupID = group.id
        groupNameDraft = group.name
        DispatchQueue.main.async { groupNameFocused = true }
    }

    private func commitGroupName(_ group: ConnectionGroup) {
        store.rename(group, to: groupNameDraft)
        editingGroupID = nil
        groupNameFocused = false
    }

    private func cancelGroupName() {
        editingGroupID = nil
        groupNameFocused = false
    }

    private func deleteSelectedGroup() {
        guard let group = selectedGroup else { return }
        delete(group)
    }

    private func delete(_ group: ConnectionGroup) {
        store.delete(group)
        if sidebarSelection == .group(group.id) {
            sidebarSelection = .allConnections
        }
    }

    private func openConnection(_ url: URL) {
        Task {
            do {
                let endpoint = try await ConnectionDocumentService.endpoint(from: url)
                openWindow(id: "authentication", value: endpoint)
            } catch {
                ConnectionDocumentService.present(error)
            }
        }
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
    let onEdit: () -> Void

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
            Button(action: onEdit) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Info")
        }
        .padding(.vertical, 7)
    }
}
