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
    private let sessionManager: SessionManager
    private var task: Task<Void, Never>?

    init(
        endpoint: ConnectionEndpoint,
        authenticator: any RFBAuthenticating = RFBAuthenticationService(),
        controlChannelNegotiator: any AppleControlChannelNegotiating = AppleControlChannelNegotiator(),
        mediaNegotiator: any AppleMediaNegotiating = AppleMediaNegotiator(),
        videoStreamStarter: any AppleVideoStreamStarting = AppleVideoStreamStarter(),
        credentialStore: any CredentialStoring = KeychainCredentialStore(),
        connectionStore: ConnectionStore,
        sessionManager: SessionManager
    ) {
        self.endpoint = endpoint
        self.authenticator = authenticator
        self.controlChannelNegotiator = controlChannelNegotiator
        self.mediaNegotiator = mediaNegotiator
        self.videoStreamStarter = videoStreamStarter
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
                    _ = try await controlChannelNegotiator.enableEncryption(for: session)
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
                    let controlMessages = AppleControlMessageService(
                        session: session,
                        input: input,
                        clipboard: clipboard,
                        pendingMessages: negotiation.pendingMessages,
                        receiveDisplayLayout: { layout in
                            try? await dynamicResolutionController?.receive(layout)
                        },
                        receiveMediaCanvas: { canvas in
                            await dynamicResolutionController?.receiveMediaCanvas(canvas)
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
