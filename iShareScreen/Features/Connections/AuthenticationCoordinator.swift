import Combine
import Foundation

@MainActor
final class AuthenticationCoordinator: ObservableObject {
    enum State: Equatable {
        case idle
        case authenticating
        case authenticated
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    let endpoint: ConnectionEndpoint
    private let authenticator: any RFBAuthenticating
    private let credentialStore: any CredentialStoring
    private let connectionStore: ConnectionStore
    private let sessionManager: SessionManager
    private var task: Task<Void, Never>?

    init(
        endpoint: ConnectionEndpoint,
        authenticator: any RFBAuthenticating = RFBAuthenticationService(),
        credentialStore: any CredentialStoring = KeychainCredentialStore(),
        connectionStore: ConnectionStore,
        sessionManager: SessionManager
    ) {
        self.endpoint = endpoint
        self.authenticator = authenticator
        self.credentialStore = credentialStore
        self.connectionStore = connectionStore
        self.sessionManager = sessionManager
    }

    func savedCredentials() -> ScreenSharingCredentials? {
        try? credentialStore.load(for: endpoint)
    }

    func signIn(username: String, password: String, rememberPassword: Bool) {
        task?.cancel()
        do {
            let credentials = try ScreenSharingCredentials(username: username, password: password)
            state = .authenticating
            task = Task {
                do {
                    let session = try await authenticator.connect(to: endpoint, credentials: credentials)
                    try Task.checkCancellation()
                    if rememberPassword {
                        try credentialStore.save(credentials, for: endpoint)
                    } else {
                        try credentialStore.delete(for: endpoint)
                    }
                    sessionManager.install(session)
                    connectionStore.record(endpoint)
                    state = .authenticated
                } catch is CancellationError {
                    state = .idle
                } catch {
                    state = .failed(error.localizedDescription)
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }
}

