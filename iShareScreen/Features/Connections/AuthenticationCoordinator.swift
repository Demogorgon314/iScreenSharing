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
    private let sessionFeaturePreferences: SessionFeaturePreferences
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
        sessionFeaturePreferences: SessionFeaturePreferences = SessionFeaturePreferences(),
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
                        displaySizes: initialDisplaySizes
                    )
                    let negotiation = try await mediaNegotiator.negotiate(
                        session,
                        displayCount: virtualDisplayCount.rawValue
                    )
                    let input = AppleInputController(session: session, canvas: negotiation.canvas)
                    session.install(inputController: input)
                    let clipboard = AppleClipboardService(
                        advertise: { [weak input] archive in
                            guard let input else { throw CancellationError() }
                            try await input.sendClipboard(archive, promises: true)
                        }
                    )
                    try videoStreamStarter.startVideo(for: session, negotiation: negotiation)
                    let dynamicResolutionController: AppleDynamicResolutionController?
                    if virtualDisplayCount == .one, let stream = session.videoStream {
                        let controller = AppleDynamicResolutionController(
                            initialCanvas: negotiation.canvas,
                            mediaConfiguration: negotiation.configuration,
                            sendMessage: { [weak session] message in
                                guard let session else { return }
                                try await session.sendEncrypted(message)
                            },
                            applyCanvas: { [weak stream, weak input] canvas in
                                await stream?.updateCanvas(canvas)
                                await input?.update(canvas: canvas)
                            },
                            prepareMediaRestart: { [weak stream] in
                                await stream?.prepareForMediaRestart()
                            }
                        )
                        session.install(dynamicResolutionController: controller)
                        dynamicResolutionController = controller
                    } else {
                        dynamicResolutionController = nil
                    }
                    let cursorStore = AppleCursorStore()
                    session.install(cursorStore: cursorStore)
                    let remoteSystemCapabilities = AppleRemoteSystemCapabilities()
                    session.install(remoteSystemCapabilities: remoteSystemCapabilities)
                    let keyboardInputSource = AppleKeyboardInputSourceService(
                        isSharingEnabled: sessionFeaturePreferences.sharesKeyboardInputSource,
                        send: { [weak session] message in
                            guard let session else { return }
                            try await session.sendEncrypted(message)
                        },
                        updateUsesSameInputSource: { [weak input] usesSameInputSource in
                            await input?.setUsesSameInputSource(usesSameInputSource)
                        },
                        didChangeSharingEnabled: sessionFeaturePreferences.setSharesKeyboardInputSource
                    )
                    session.install(keyboardInputSourceService: keyboardInputSource)
                    let displayLayoutModel = AppleDisplayLayoutModel(
                        expectedDisplayCount: virtualDisplayCount.rawValue
                    )
                    displayLayoutModel.receivePendingMessages(negotiation.pendingMessages)
                    if let initialLayout = displayLayoutModel.layout,
                       initialLayout.displays.count > 1 {
                        await input.update(canvas: initialLayout.canvas(
                            tileCount: negotiation.canvas.tileCount
                        ))
                    }
                    session.install(displayLayoutModel: displayLayoutModel)
                    session.install(dynamicResolutionModel: AppleDynamicResolutionModel(
                        displayCount: virtualDisplayCount.rawValue,
                        isEnabled: sessionFeaturePreferences.usesDynamicResolution,
                        didChangeEnabled: sessionFeaturePreferences.setUsesDynamicResolution
                    ))
                    let controlMessages = AppleControlMessageService(
                        session: session,
                        input: input,
                        clipboard: clipboard,
                        pendingMessages: negotiation.pendingMessages,
                        receiveDisplayLayout: { layout in
                            await displayLayoutModel.receive(layout)
                            if layout.displays.count > 1 {
                                let width = layout.displays.map { $0.x + $0.width }.max()
                                    ?? negotiation.canvas.width
                                let height = layout.displays.map { $0.y + $0.height }.max()
                                    ?? negotiation.canvas.height
                                await input.update(canvas: AppleCanvas(
                                    width: width,
                                    height: height,
                                    tileCount: negotiation.canvas.tileCount
                                ))
                            }
                            try? await dynamicResolutionController?.receive(layout)
                        },
                        receiveMediaCanvas: { canvas in
                            await dynamicResolutionController?.receiveMediaCanvas(canvas)
                        },
                        receiveCursorUpdate: { update in
                            cursorStore.apply(update)
                        },
                        receiveVendorKeySymbols: { symbols in
                            await remoteSystemCapabilities.receive(keySymbols: symbols)
                        },
                        receiveKeyboardInputSource: { state in
                            await keyboardInputSource.receive(state)
                        },
                        receiveDeviceInfo: {
                            [connectionStore = self.connectionStore, endpoint = self.endpoint] info in
                            await MainActor.run {
                                connectionStore.record(endpoint, deviceInfo: info)
                            }
                        }
                    )
                    session.install(
                        controlMessageService: controlMessages,
                        clipboardService: clipboard
                    )
                    session.install(controlState: AppleSessionControlState(session: session))
                    controlMessages.start()
                    clipboard.start()
                    keyboardInputSource.start()
                    if let receiver = session.mediaReceiver,
                       let audio = try? AppleAudioStream(
                           receiver: receiver,
                           negotiation: negotiation,
                           isMuted: sessionFeaturePreferences.mutesAudio,
                           didChangeMuted: sessionFeaturePreferences.setMutesAudio
                       ) {
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
