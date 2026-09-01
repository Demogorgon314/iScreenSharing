import AppKit
import SwiftUI

struct ConnectionEditorView: View {
    let connection: SavedConnection
    @ObservedObject var store: ConnectionStore
    let onConnect: (ConnectionEndpoint) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var serverAddress: String
    @State private var username: String
    @State private var sharingType: ScreenSharingType
    @State private var standardQuality: StandardRFBQuality
    @State private var virtualDisplayCount: VirtualDisplayCount
    @State private var port: String
    @State private var errorMessage: String?

    init(
        connection: SavedConnection,
        store: ConnectionStore,
        onConnect: @escaping (ConnectionEndpoint) -> Void
    ) {
        self.connection = connection
        self.store = store
        self.onConnect = onConnect
        _name = State(initialValue: connection.name)
        _serverAddress = State(initialValue: Self.serverAddress(for: connection.endpoint))
        _username = State(initialValue: connection.preferredUsername)
        _sharingType = State(initialValue: connection.sharingType)
        _standardQuality = State(initialValue: connection.standardQuality)
        _virtualDisplayCount = State(initialValue: connection.virtualDisplayCount)
        _port = State(initialValue: String(connection.endpoint.port))
    }

    var body: some View {
        VStack(spacing: 16) {
            Form {
                TextField("Name", text: $name)
                    .disabled(isTailscaleConnection)
                TextField("Server Address", text: $serverAddress)
                    .disabled(isTailscaleConnection)
                TextField("Username", text: $username)
                Picker("Screen Sharing Type", selection: $sharingType) {
                    ForEach(ScreenSharingType.allCases, id: \.self) { type in
                        Text(type.title).tag(type)
                    }
                }
                if sharingType == .highPerformance {
                    Picker("Display Type", selection: $virtualDisplayCount) {
                        ForEach(VirtualDisplayCount.allCases, id: \.self) { count in
                            Text(count.title).tag(count)
                        }
                    }
                } else {
                    Picker("Image Quality", selection: $standardQuality) {
                        ForEach(StandardRFBQuality.allCases, id: \.self) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                }
                TextField("Port", text: $port)
                    .disabled(isTailscaleConnection)
            }
            .formStyle(.grouped)

            Text("Last connected \(connection.lastConnectedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Help") { NSApp.showHelp(nil) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { save(connect: true) }
                    .nativeConnectButtonFeedback()
                Button("Done") { save(connect: false) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func save(connect: Bool) {
        do {
            let endpoint = try editedEndpoint()
            try store.update(
                connection,
                name: name,
                endpoint: endpoint,
                preferredUsername: username,
                sharingType: sharingType,
                standardQuality: standardQuality,
                virtualDisplayCount: virtualDisplayCount
            )
            dismiss()
            if connect { onConnect(endpoint) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func editedEndpoint() throws -> ConnectionEndpoint {
        if isTailscaleConnection {
            return connection.endpoint
        }
        let address = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let portNumber = UInt16(port), portNumber > 0 else {
            throw ConnectionEditorError.invalidPort
        }
        if address == Self.serverAddress(for: connection.endpoint),
           portNumber == connection.endpoint.port {
            return connection.endpoint
        }
        return try ConnectionEndpoint(host: address, port: portNumber)
    }

    private static func serverAddress(for endpoint: ConnectionEndpoint) -> String {
        guard let service = endpoint.bonjourService else { return endpoint.host }
        return "\(service.name).\(service.type).\(service.domain)"
    }

    private var isTailscaleConnection: Bool {
        connection.endpoint.route == .tailscale
    }
}

private enum ConnectionEditorError: LocalizedError {
    case invalidPort

    var errorDescription: String? { "The port must be between 1 and 65535." }
}
