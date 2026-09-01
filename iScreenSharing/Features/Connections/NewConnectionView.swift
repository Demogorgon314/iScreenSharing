import SwiftUI

struct NewConnectionView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @StateObject private var coordinator: ConnectionCoordinator
    @State private var address = ""
    @State private var validationMessage: String?
    @FocusState private var addressFocused: Bool

    init() {
        _coordinator = StateObject(wrappedValue: ConnectionCoordinator())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Connect To:")
                    .fontWeight(.medium)
                TextField("Hostname or IP Address", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .focused($addressFocused)
                    .onSubmit(connect)
                    .disabled(coordinator.state == .connecting)
            }

            if let message = validationMessage ?? failureMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                if coordinator.state == .connecting {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Cancel") {
                    coordinator.cancel()
                    dismissWindow(id: "new-connection")
                }
                .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    connect()
                }
                .keyboardShortcut(.defaultAction)
                .nativeConnectButtonFeedback()
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || coordinator.state == .connecting)
            }
        }
        .padding(20)
        .frame(width: 430)
        .onAppear { addressFocused = true }
        .onChange(of: coordinator.state) { _, state in
            guard case .ready = state, let endpoint = try? ConnectionEndpoint(address) else { return }
            openWindow(id: "authentication", value: endpoint)
            dismissWindow(id: "new-connection")
        }
    }

    private var failureMessage: String? {
        guard case .failed(let message) = coordinator.state else { return nil }
        return message
    }

    private func connect() {
        do {
            let endpoint = try ConnectionEndpoint(address)
            validationMessage = nil
            coordinator.connect(to: endpoint)
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}
