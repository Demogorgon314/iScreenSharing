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
    private let sessionActivator: any SessionActivating
    private let credentialStore: any CredentialStoring
    private let connectionStore: ConnectionStore
    private let viewportStore: SessionViewportStore
    private let sessionFeaturePreferences: SessionFeaturePreferences
    private let sessionManager: SessionManager
    private let onAuthenticated: @MainActor (ConnectionEndpoint) -> Void
    private var task: Task<Void, Never>?

    init(
        endpoint: ConnectionEndpoint,
        sessionActivator: (any SessionActivating)? = nil,
        credentialStore: any CredentialStoring = KeychainCredentialStore(),
        connectionStore: ConnectionStore,
        viewportStore: SessionViewportStore = SessionViewportStore(),
        sessionFeaturePreferences: SessionFeaturePreferences = SessionFeaturePreferences(),
        sessionManager: SessionManager,
        onAuthenticated: @escaping @MainActor (ConnectionEndpoint) -> Void = { _ in }
    ) {
        self.endpoint = endpoint
        self.sessionActivator = sessionActivator ?? SessionActivation(
            connectionStore: connectionStore,
            sessionFeaturePreferences: sessionFeaturePreferences
        )
        self.credentialStore = credentialStore
        self.connectionStore = connectionStore
        self.viewportStore = viewportStore
        self.sessionFeaturePreferences = sessionFeaturePreferences
        self.sessionManager = sessionManager
        self.onAuthenticated = onAuthenticated
    }

    func savedCredentials() async -> ScreenSharingCredentials? {
        let credentialStore = credentialStore
        let endpoint = endpoint
        return await Task.detached {
            try? credentialStore.load(for: endpoint)
        }.value
    }

    @discardableResult
    func signInWithSavedCredentials() async -> ScreenSharingCredentials? {
        guard let credentials = await savedCredentials(), !Task.isCancelled else {
            return nil
        }
        signIn(
            username: credentials.username,
            password: credentials.password,
            rememberPassword: true
        )
        return credentials
    }

    func preferredUsername() -> String? {
        let username = connectionStore.connection(for: endpoint)?.preferredUsername ?? ""
        return username.isEmpty ? nil : username
    }

    func signIn(username: String, password: String, rememberPassword: Bool) {
        task?.cancel()
        do {
            let savedConnection = connectionStore.connection(for: endpoint)
            let virtualDisplayCount = savedConnection?.virtualDisplayCount ?? .one
            let fallbackDisplaySize = viewportStore.size(for: endpoint)
                .flatMap(AppleDynamicResolutionSize.normalized(viewport:))
                ?? AppleDynamicResolutionSize(width: 1440, height: 900)
            let initialDisplaySizes = (0..<virtualDisplayCount.rawValue).map { displayIndex in
                viewportStore.size(for: endpoint, displayIndex: displayIndex)
                    .flatMap(AppleDynamicResolutionSize.normalized(viewport:))
                    ?? fallbackDisplaySize
            }
            let requestedDisplaySizes = virtualDisplayCount == .one
                && !sessionFeaturePreferences.usesDynamicResolution
                ? [.fixed1080p]
                : initialDisplaySizes
            let sharingType = savedConnection?.sharingType ?? .highPerformance
            let standardQuality = savedConnection?.standardQuality ?? .high
            let credentials = try ScreenSharingCredentials(username: username, password: password)
            state = .authenticating
            task = Task {
                do {
                    let session = try await sessionActivator.activate(
                        endpoint: endpoint,
                        credentials: credentials,
                        configuration: SessionActivationConfiguration(
                            sharingType: sharingType,
                            standardQuality: standardQuality,
                            virtualDisplayCount: virtualDisplayCount,
                            requestedDisplaySizes: requestedDisplaySizes
                        )
                    )
                    sessionManager.install(session)
                    connectionStore.record(
                        endpoint,
                        preferredUsername: credentials.username,
                        standardQuality: sharingType == .standard ? standardQuality : nil
                    )
                    onAuthenticated(endpoint)
                    state = .authenticated
                    persistCredentialsInBackground(credentials, remember: rememberPassword)
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

    private func persistCredentialsInBackground(
        _ credentials: ScreenSharingCredentials,
        remember: Bool
    ) {
        let credentialStore = credentialStore
        let endpoint = endpoint
        Task.detached {
            if remember {
                try? credentialStore.save(credentials, for: endpoint)
            } else {
                try? credentialStore.delete(for: endpoint)
            }
        }
    }
}
