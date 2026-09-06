import SwiftUI

struct MobileConnectionsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var discovery = NetworkDiscoveryModel()
    @StateObject private var store = ConnectionStore()
    @State private var path = [ConnectionEndpoint]()
    @State private var showsNewConnection = false
    @State private var editingConnection: SavedConnection?
    @State private var searchText = ""
    @State private var connectionToDelete: SavedConnection?

    var body: some View {
        NavigationStack(path: $path) {
            connectionList
            .navigationTitle("Connections")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New Connection", systemImage: "plus") {
                        showsNewConnection = true
                    }
                }
            }
            .navigationDestination(for: ConnectionEndpoint.self) { endpoint in
                MobileConnectionPlaceholderView(endpoint: endpoint, store: store)
            }
        }
        .sheet(isPresented: $showsNewConnection) {
            MobileNewConnectionView(store: store) { endpoint in
                showsNewConnection = false
                path.append(endpoint)
            }
        }
        .sheet(item: $editingConnection) { connection in
            MobileNewConnectionView(store: store, connection: connection) { endpoint in
                editingConnection = nil
                path.append(endpoint)
            }
        }
        .confirmationDialog("Remove Saved Connection?", isPresented: Binding(
            get: { connectionToDelete != nil },
            set: { if !$0 { connectionToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let connectionToDelete { store.delete(connectionToDelete) }
                connectionToDelete = nil
            }
        } message: {
            Text("Only the saved configuration is removed. Stored passwords are kept, and the Mac may still appear nearby.")
        }
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            await discovery.browse()
        }
    }

    private var connectionList: some View {
        List {
            if !filteredConnections.isEmpty {
                Section {
                    ForEach(filteredConnections) { connection in
                        connectionRow(connection.endpoint, name: connection.name, saved: connection)
                    }
                } header: {
                    Text("Saved Connections")
                } footer: {
                    Text("Tap to connect. Touch and hold for connection options.")
                }
            }
            Section("Nearby") { nearbyConnections }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: "Name or address")
    }

    private var filteredConnections: [SavedConnection] {
        store.connections.filter { matchesSearch(name: $0.name, endpoint: $0.endpoint) }
    }

    private func matchesSearch(name: String, endpoint: ConnectionEndpoint) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || name.localizedStandardContains(query)
            || endpoint.displayName.localizedStandardContains(query)
    }

    private func connectionRow(
        _ endpoint: ConnectionEndpoint, name: String, saved: SavedConnection? = nil,
        discovered: DiscoveredScreenSharingService? = nil
    ) -> some View {
        NavigationLink(value: endpoint) {
            HStack(spacing: 14) {
                Image(systemName: "desktopcomputer")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.headline)
                    Text(name == endpoint.displayName ? "Screen Sharing" : endpoint.displayName)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
        }
        .contextMenu {
            Button("Connect", systemImage: "arrow.up.right") { path.append(endpoint) }
            Button("Edit Connection", systemImage: "pencil") {
                editingConnection = saved ?? SavedConnection(endpoint: endpoint, deviceInfo: discovered?.deviceInfo)
            }
            if let saved {
                Button("Remove Saved Connection", systemImage: "trash", role: .destructive) {
                    connectionToDelete = saved
                }
            }
        }
        .accessibilityHint("Connect to this Mac. Connection options are available in the context menu.")
        .accessibilityAction(named: "Edit Connection") {
            editingConnection = saved ?? SavedConnection(endpoint: endpoint, deviceInfo: discovered?.deviceInfo)
        }
    }

    @ViewBuilder
    private var nearbyConnections: some View {
        switch discovery.state {
        case .searching:
            HStack(spacing: 12) {
                ProgressView()
                Text("Looking for Macs…")
                    .foregroundStyle(.secondary)
            }
        case .results(let services) where services.isEmpty:
            ContentUnavailableView {
                Label("No Macs Found", systemImage: "rectangle.connected.to.line.below")
            } description: {
                Text("Enter a hostname or IP address to connect directly.")
            } actions: {
                Button("New Connection") { showsNewConnection = true }
                    .buttonStyle(.borderedProminent)
            }
        case .results(let services):
            let visible = services.filter {
                store.connection(for: $0.endpoint) == nil
                    && matchesSearch(name: $0.endpoint.displayName, endpoint: $0.endpoint)
            }
            if visible.isEmpty {
                Text(searchText.isEmpty ? "Nearby Macs are already in Saved Connections." : "No matching nearby Macs.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visible, id: \.endpoint) { service in
                    connectionRow(service.endpoint, name: service.endpoint.displayName, discovered: service)
                }
            }
        case .failed(let message):
            ContentUnavailableView(
                "Discovery Unavailable",
                systemImage: "wifi.exclamationmark",
                description: Text(message)
            )
        }
    }
}

private struct MobileNewConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ConnectionStore
    let connection: SavedConnection?
    @State private var draft: MobileConnectionDraft
    @State private var errorMessage: String?

    let connect: (ConnectionEndpoint) -> Void

    init(store: ConnectionStore, connection: SavedConnection? = nil, connect: @escaping (ConnectionEndpoint) -> Void) {
        self.store = store
        self.connection = connection
        self.connect = connect
        _draft = State(initialValue: MobileConnectionDraft(connection: connection))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Remote Mac") {
                    LabeledContent("Name") {
                        TextField("Name", text: $draft.name, prompt: Text(draft.address))
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Server Address") {
                        TextField("Hostname or IP", text: $draft.address)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Username") {
                        TextField("Username", text: $draft.username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Screen Sharing Type", value: ScreenSharingType.highPerformance.title)
                    LabeledContent("Display Type", value: VirtualDisplayCount.one.title)
                    LabeledContent("Port") {
                        TextField("Port", text: $draft.port)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                }

                if let connection,
                   let recent = store.recentConnections.first(where: { $0.endpoint == connection.endpoint }) {
                    Section {
                        Text("Last connected \(recent.lastConnectedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section { Button("Connect") { save(connect: true) } }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(connection == nil ? "New Connection" : "Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(connect: false) }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func save(connect shouldConnect: Bool) {
        do {
            let existing = connection.flatMap { candidate in store.connections.first { $0.id == candidate.id } }
            let saved = try draft.save(in: store, editing: existing)
            dismiss()
            if shouldConnect { connect(saved.endpoint) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct MobileVideoPerformanceOverlay: View {
    @ObservedObject var performance: AppleVideoPerformanceMonitor

    var body: some View {
        let stats = performance.snapshot
        VStack(alignment: .leading, spacing: 3) {
            Text(String(format: "Display  %.1f fps", stats.displayedFramesPerSecond))
            Text(String(
                format: "Decode   %.1f fps / %.2f ms",
                stats.decodedFramesPerSecond,
                stats.averageDecodeMilliseconds
            ))
            Text(String(
                format: "Frame    %.2f ms / P95 %.2f ms",
                stats.averageDisplayFrameMilliseconds,
                stats.p95DisplayFrameMilliseconds
            ))
            Text(String(
                format: "Network  %.1f Mb/s / loss %.2f%%",
                stats.networkMegabitsPerSecond,
                stats.receiverReportLossPercentage
            ))
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.74), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Video performance statistics")
    }
}

private struct MobileConnectionPlaceholderView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SessionFeaturePreferences.showsVideoPerformanceOverlayKey)
    private var showsVideoPerformanceOverlay = false
    @AppStorage(SessionFeaturePreferences.showsMetalPerformanceHUDKey)
    private var showsMetalPerformanceHUD = false
    let endpoint: ConnectionEndpoint
    @ObservedObject private var store: ConnectionStore

    @StateObject private var controller: MobileSessionController
    @State private var username = ""
    @State private var password = ""
    @State private var rememberPassword = false
    @State private var requestsKeyboard = false
    @State private var didPrepareConnection = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case username
        case password
    }

    init(endpoint: ConnectionEndpoint, store: ConnectionStore) {
        self.endpoint = endpoint
        self.store = store
        _username = State(initialValue: store.connection(for: endpoint)?.preferredUsername ?? "")
        _controller = StateObject(wrappedValue: MobileSessionController(endpoint: endpoint))
    }

    var body: some View {
        Group {
            if let session = controller.session,
               let stream = session.videoStream as? AppleVideoStream {
                MobileVideoCanvasView(
                    stream: stream,
                    input: session.inputController,
                    cursors: session.cursorStore,
                    requestsKeyboard: $requestsKeyboard,
                    showsMetalPerformanceHUD: showsMetalPerformanceHUD,
                    supportsPreciseScrolling: session.serverInfo.supportsServerCommand(23)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                .overlay(alignment: .topLeading) {
                    if showsVideoPerformanceOverlay {
                        GeometryReader { geometry in
                            MobileVideoPerformanceOverlay(performance: stream.performance)
                                .padding(.top, geometry.safeAreaInsets.top + 8)
                                .padding(.horizontal, geometry.safeAreaInsets.leading + 8)
                        }
                        .allowsHitTesting(false)
                    }
                }
            } else if !didPrepareConnection || controller.state == .connecting {
                ProgressView("Connecting…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                loginForm
            }
        }
        .ignoresSafeArea(.keyboard, edges: controller.state == .connected ? .bottom : [])
        .navigationTitle(store.connection(for: endpoint)?.name ?? endpoint.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(controller.state == .connected ? .hidden : .automatic, for: .navigationBar)
        .toolbar {
            if controller.state == .connected {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Toggle("Video Performance", isOn: $showsVideoPerformanceOverlay)
                        Toggle("Metal HUD", isOn: $showsMetalPerformanceHUD)
                    } label: {
                        Label("Performance", systemImage: "waveform.path.ecg.rectangle")
                    }
                    Button {
                        requestsKeyboard.toggle()
                    } label: {
                        Label("Keyboard", systemImage: "keyboard")
                    }
                    Menu {
                        ForEach(MobileResolutionPreset.allCases) { preset in
                            Button {
                                controller.requestResolution(preset)
                            } label: {
                                if controller.selectedResolutionPreset == preset {
                                    Label(preset.title, systemImage: "checkmark")
                                } else {
                                    Text(preset.title)
                                }
                            }
                        }
                    } label: {
                        Label("Resolution", systemImage: "display")
                    }
                }
            }
        }
        .onDisappear { controller.disconnect() }
        .task {
            guard !didPrepareConnection else { return }
            let credentials = await controller.savedCredentials(preferredUsername: username)
            guard !Task.isCancelled else { return }
            didPrepareConnection = true
            if let credentials {
                username = credentials.username
                password = credentials.password
                rememberPassword = true
                connect()
            } else {
                focusedField = username.isEmpty ? .username : .password
            }
        }
        .onChange(of: controller.state) { _, state in
            if state == .connected { store.record(endpoint, preferredUsername: username) }
        }
        .onChange(of: scenePhase) { _, phase in
            controller.setActive(phase == .active)
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            controller.updateViewport(size)
        }
        .alert(
            "Unable to Change Resolution",
            isPresented: Binding(
                get: { controller.resolutionErrorMessage != nil },
                set: { if !$0 { controller.clearResolutionError() } }
            )
        ) {
            Button("OK") { controller.clearResolutionError() }
        } message: {
            Text(controller.resolutionErrorMessage ?? "The remote Mac rejected the display change.")
        }
    }

    private var loginForm: some View {
        Form {
            Section {
                TextField("User Name", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focusedField, equals: .password)
                    .onSubmit(connect)
                Toggle("Remember Password", isOn: $rememberPassword)
            } header: {
                Text("Registered User")
            } footer: {
                Text("Sign in with an account allowed to use Screen Sharing on this Mac.")
            }

            if case .failed(let message) = controller.state {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button(action: connect) {
                    HStack {
                        Spacer()
                        if controller.state == .connecting {
                            ProgressView()
                        } else {
                            Text("Connect")
                        }
                        Spacer()
                    }
                }
                .disabled(username.isEmpty || password.isEmpty || controller.state == .connecting)
            }
        }
    }

    private func connect() {
        guard !username.isEmpty, !password.isEmpty else { return }
        focusedField = nil
        controller.connect(
            username: username,
            password: password,
            rememberPassword: rememberPassword
        )
    }
}
