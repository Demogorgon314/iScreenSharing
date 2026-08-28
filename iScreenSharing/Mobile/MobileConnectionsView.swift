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
    let endpoint: ConnectionEndpoint

    @StateObject private var probeModel: MobileConnectionProbeModel

    init(endpoint: ConnectionEndpoint) {
        self.endpoint = endpoint
        _probeModel = StateObject(wrappedValue: MobileConnectionProbeModel(endpoint: endpoint))
    }

    var body: some View {
        Group {
            switch probeModel.state {
            case .idle, .probing:
                ProgressView("Contacting \(endpoint.displayName)…")
            case .ready:
                ContentUnavailableView {
                    Label(endpoint.displayName, systemImage: "checkmark.circle")
                } description: {
                    Text("This Mac supports Apple high-performance Screen Sharing authentication.")
                }
            case .unsupported:
                ContentUnavailableView {
                    Label("Unsupported Mac", systemImage: "xmark.circle")
                } description: {
                    Text("The host did not advertise Apple RSA Screen Sharing authentication.")
                }
            case .failed(let message):
                ContentUnavailableView {
                    Label("Connection Failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await probeModel.start() } }
                }
            }
        }
        .navigationTitle(endpoint.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await probeModel.start() }
    }
}
