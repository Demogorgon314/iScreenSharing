import SwiftUI

struct MobileConnectionsView: View {
    @State private var path = [ConnectionEndpoint]()
    @State private var showsNewConnection = false

    var body: some View {
        NavigationStack(path: $path) {
            ContentUnavailableView {
                Label("No Connections", systemImage: "rectangle.connected.to.line.below")
            } description: {
                Text("Connect directly to a Mac running Screen Sharing.")
            } actions: {
                Button("New Connection") { showsNewConnection = true }
                    .buttonStyle(.borderedProminent)
            }
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

    var body: some View {
        ContentUnavailableView {
            Label(endpoint.displayName, systemImage: "display")
        } description: {
            Text("Connection setup is ready. Authentication and video are added in the next milestone.")
        }
        .navigationTitle(endpoint.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}
