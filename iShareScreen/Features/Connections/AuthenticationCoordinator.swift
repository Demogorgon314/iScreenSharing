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
    private let controlChannelNegotiator: any AppleControlChannelNegotiating
    private let mediaNegotiator: any AppleMediaNegotiating
    private let videoStreamStarter: any AppleVideoStreamStarting
    private let credentialStore: any CredentialStoring
    private let connectionStore: ConnectionStore
    private let viewportStore: SessionViewportStore
    private let sessionManager: SessionManager
    private let onAuthenticated: @MainActor (ConnectionEndpoint) -> Void
    private var task: Task<Void, Never>?

    init(
        endpoint: ConnectionEndpoint,
        authenticator: any RFBAuthenticating = RFBAuthenticationService(),
        controlChannelNegotiator: any AppleControlChannelNegotiating = AppleControlChannelNegotiator(),
        mediaNegotiator: any AppleMediaNegotiating = AppleMediaNegotiator(),
        videoStreamStarter: any AppleVideoStreamStarting = AppleVideoStreamStarter(),
        credentialStore: any CredentialStoring = KeychainCredentialStore(),
        connectionStore: ConnectionStore,
        viewportStore: SessionViewportStore = SessionViewportStore(),
        sessionManager: SessionManager,
        onAuthenticated: @escaping @MainActor (ConnectionEndpoint) -> Void = { _ in }
    ) {
        self.endpoint = endpoint
        self.authenticator = authenticator
        self.controlChannelNegotiator = controlChannelNegotiator
        self.mediaNegotiator = mediaNegotiator
        self.videoStreamStarter = videoStreamStarter
        self.credentialStore = credentialStore
        self.connectionStore = connectionStore
        self.viewportStore = viewportStore
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

    func preferredUsername() -> String? {
        let username = connectionStore.connection(for: endpoint)?.preferredUsername ?? ""
        return username.isEmpty ? nil : username
    }

    func signIn(username: String, password: String, rememberPassword: Bool) {
        task?.cancel()
        do {
            let savedConnection = connectionStore.connection(for: endpoint)
            let initialDisplaySize = viewportStore.size(for: endpoint)
                .flatMap(AppleDynamicResolutionSize.normalized(viewport:))
                ?? AppleDynamicResolutionSize(width: 1440, height: 900)
            guard savedConnection?.sharingType != .standard else {
                throw AuthenticationCoordinatorError.standardModeUnavailable
            }
            let credentials = try ScreenSharingCredentials(username: username, password: password)
            state = .authenticating
            task = Task {
                do {
                    let session = try await authenticator.connect(to: endpoint, credentials: credentials)
                    _ = try await controlChannelNegotiator.enableEncryption(
                        for: session,
                        virtualDisplayCount: savedConnection?.virtualDisplayCount ?? .one,
                        displaySize: initialDisplaySize
                    )
                    let negotiation = try await mediaNegotiator.negotiate(session)
                    let input = AppleInputController(session: session, canvas: negotiation.canvas)
                    session.install(inputController: input)
                    let clipboard = AppleClipboardService()
                    try videoStreamStarter.startVideo(for: session, negotiation: negotiation)
                    let dynamicResolutionController: AppleDynamicResolutionController?
                    if let stream = session.videoStream {
                        let controller = AppleDynamicResolutionController(
                            initialCanvas: negotiation.canvas,
                            mediaConfiguration: negotiation.configuration,
                            sendMessage: { [weak session] message in
                                guard let session else { return }
                                try await session.sendEncrypted(message)
                            },
                            applyCanvas: { [weak stream, weak input] canvas in
                                await stream?.reconfigure(canvas: canvas)
                                await input?.update(canvas: canvas)
                            }
                        )
                        session.install(dynamicResolutionController: controller)
                        dynamicResolutionController = controller
                    } else {
                        dynamicResolutionController = nil
                    }
                    let cursorStore = AppleCursorStore()
                    session.install(cursorStore: cursorStore)
                    let displayLayoutModel = AppleDisplayLayoutModel(
                        expectedDisplayCount: savedConnection?.virtualDisplayCount.rawValue ?? 1
                    )
                    session.install(displayLayoutModel: displayLayoutModel)
                    let controlMessages = AppleControlMessageService(
                        session: session,
                        input: input,
                        clipboard: clipboard,
                        pendingMessages: negotiation.pendingMessages,
                        receiveDisplayLayout: { layout in
                            await displayLayoutModel.receive(layout)
                            try? await dynamicResolutionController?.receive(layout)
                        },
                        receiveMediaCanvas: { canvas in
                            await dynamicResolutionController?.receiveMediaCanvas(canvas)
                        },
                        receiveCursorUpdate: { update in
                            cursorStore.apply(update)
                        }
                    )
                    session.install(
                        controlMessageService: controlMessages,
                        clipboardService: clipboard
                    )
                    controlMessages.start()
                    if let receiver = session.mediaReceiver,
                       let audio = try? AppleAudioStream(receiver: receiver, negotiation: negotiation) {
                        session.install(audioStream: audio)
                        audio.start()
                    }
                    try Task.checkCancellation()
                    sessionManager.install(session)
                    connectionStore.record(endpoint, preferredUsername: credentials.username)
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

enum AuthenticationCoordinatorError: LocalizedError, Equatable {
    case standardModeUnavailable

    var errorDescription: String? {
        "Standard Screen Sharing is not implemented yet. Choose High Performance in the connection settings."
    }
}
