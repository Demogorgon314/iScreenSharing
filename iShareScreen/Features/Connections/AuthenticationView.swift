import SwiftUI

struct AuthenticationView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @StateObject private var coordinator: AuthenticationCoordinator
    @ObservedObject private var sessions: SessionManager
    @State private var username = ""
    @State private var password = ""
    @State private var rememberPassword = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case username
        case password
    }

    init(endpoint: ConnectionEndpoint, store: ConnectionStore, sessions: SessionManager) {
        self.sessions = sessions
        _coordinator = StateObject(
            wrappedValue: AuthenticationCoordinator(
                endpoint: endpoint,
                connectionStore: store,
                sessionManager: sessions,
                onAuthenticated: { endpoint in
                    SessionWindowCoordinator.shared.show(endpoint: endpoint, sessions: sessions)
                }
            )
        )
    }

    var body: some View {
        authenticationContent
            .onChange(of: coordinator.state) { _, state in
                guard state == .authenticated else { return }
                dismissWindow(id: "authentication", value: coordinator.endpoint)
                DispatchQueue.main.async {
                    SessionWindowCoordinator.shared.show(
                        endpoint: coordinator.endpoint,
                        sessions: sessions
                    )
                }
            }
    }

    private var authenticationContent: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "rectangle.inset.filled.and.person.filled")
                    .font(.system(size: 48, weight: .regular))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.indigo, .blue)
                    .frame(width: 58, height: 58)

                VStack(alignment: .leading, spacing: 14) {
                    Text("Screen Sharing requires a user name and password to sign in to “\(coordinator.endpoint.displayName)”.")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)

                    Grid(alignment: .trailingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
                        GridRow {
                            Text("Connect:")
                            VStack(alignment: .leading, spacing: 5) {
                                Label("By Requesting Permission", systemImage: "circle")
                                    .foregroundStyle(.secondary)
                                Label("As Registered User", systemImage: "circle.inset.filled")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        GridRow {
                            Text("User Name:")
                            TextField("Name", text: $username)
                                .focused($focusedField, equals: .username)
                        }
                        GridRow {
                            Text("Password:")
                            SecureField("Password", text: $password)
                                .focused($focusedField, equals: .password)
                                .onSubmit(signIn)
                        }
                        GridRow {
                            Color.clear.frame(width: 1, height: 1)
                            Toggle("Remember password", isOn: $rememberPassword)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }

            if case .failed(let message) = coordinator.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                if coordinator.state == .authenticating {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Cancel") {
                    coordinator.cancel()
                    dismissWindow(id: "authentication", value: coordinator.endpoint)
                }
                .keyboardShortcut(.cancelAction)
                Button("Sign In") {
                    signIn()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(username.isEmpty || password.isEmpty || coordinator.state == .authenticating)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            if let saved = coordinator.savedCredentials() {
                username = saved.username
                password = saved.password
                rememberPassword = true
                focusedField = .password
            } else {
                if let preferredUsername = coordinator.preferredUsername() {
                    username = preferredUsername
                    focusedField = .password
                } else {
                    focusedField = .username
                }
            }
        }
    }

    private func signIn() {
        coordinator.signIn(
            username: username,
            password: password,
            rememberPassword: rememberPassword
        )
    }
}
