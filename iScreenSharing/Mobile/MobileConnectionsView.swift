import SwiftUI

struct MobileConnectionsView: View {
    @StateObject private var discovery = NetworkDiscoveryModel()
    @State private var path = [ConnectionEndpoint]()
    @State private var showsNewConnection = false

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
                MobileConnectionPlaceholderView(endpoint: endpoint)
            }
        }
        .sheet(isPresented: $showsNewConnection) {
            MobileNewConnectionView { endpoint in
                showsNewConnection = false
                path.append(endpoint)
            }
        }
        .task { await discovery.browse() }
    }

    @ViewBuilder
    private var connectionList: some View {
        switch discovery.state {
        case .searching:
            List {
                Section("Nearby") {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Looking for Macs…")
                            .foregroundStyle(.secondary)
                    }
                }
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
            List(services, id: \.endpoint) { service in
                NavigationLink(value: service.endpoint) {
                    Label(service.endpoint.displayName, systemImage: "desktopcomputer")
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
    @State private var draft = MobileConnectionDraft()
    @State private var errorMessage: String?

    let connect: (ConnectionEndpoint) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Remote Mac") {
                    TextField("Hostname or IP address", text: $draft.address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit(validateAndConnect)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect", action: validateAndConnect)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func validateAndConnect() {
        do {
            connect(try draft.endpoint())
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct MobileConnectionPlaceholderView: View {
    @Environment(\.scenePhase) private var scenePhase
    let endpoint: ConnectionEndpoint

    @StateObject private var controller: MobileSessionController
    @State private var username = ""
    @State private var password = ""
    @State private var rememberPassword = false
    @State private var requestsKeyboard = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case username
        case password
    }

    init(endpoint: ConnectionEndpoint) {
        self.endpoint = endpoint
        _controller = StateObject(wrappedValue: MobileSessionController(endpoint: endpoint))
    }

    var body: some View {
        Group {
            if let session = controller.session, let stream = session.videoStream {
                MobileVideoCanvasView(
                    stream: stream,
                    input: session.inputController,
                    requestsKeyboard: $requestsKeyboard
                )
                .ignoresSafeArea(edges: .bottom)
            } else {
                loginForm
            }
        }
        .navigationTitle(endpoint.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if controller.state == .connected {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        requestsKeyboard.toggle()
                    } label: {
                        Label("Keyboard", systemImage: "keyboard")
                    }
                    Button(role: .destructive) {
                        controller.disconnect()
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                }
            }
        }
        .onDisappear { controller.disconnect() }
        .onChange(of: scenePhase) { _, phase in
            controller.setActive(phase == .active)
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            controller.updateViewport(size)
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
        .task {
            if let credentials = await controller.savedCredentials() {
                username = credentials.username
                password = credentials.password
                rememberPassword = true
                focusedField = .password
            } else {
                focusedField = .username
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
