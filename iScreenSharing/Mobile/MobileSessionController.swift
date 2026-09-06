import AVFAudio
import Combine
import Foundation
import enum ScreenSharingProtocol.AppleRFBMessages
import struct ScreenSharingProtocol.AppleDynamicResolutionSize
import struct ScreenSharingProtocol.AppleRemoteDeviceInfo

@MainActor
final class MobileSessionController: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var session: RFBAuthenticatedSession?
    @Published private(set) var selectedResolutionPreset: MobileResolutionPreset?
    @Published private(set) var resolutionErrorMessage: String?
    @Published private(set) var deviceInfo: AppleRemoteDeviceInfo?

    let endpoint: ConnectionEndpoint

    private let authenticator: any RFBAuthenticating
    private let controlChannelNegotiator: any AppleControlChannelNegotiating
    private let mediaNegotiator: any AppleMediaNegotiating
    private let videoStreamStarter: any AppleVideoStreamStarting
    private let credentialStore: any CredentialStoring
    private let resolutionPreferences: MobileResolutionPreferences
    private var isActive = true
    private var streamStateObserver: AnyCancellable?
    private var connectionTask: Task<Void, Never>?
    private var resolutionTask: Task<Void, Never>?
    private var viewportSize: CGSize?

    init(
        endpoint: ConnectionEndpoint,
        authenticator: any RFBAuthenticating = RFBAuthenticationService(),
        controlChannelNegotiator: any AppleControlChannelNegotiating = AppleControlChannelNegotiator(),
        mediaNegotiator: any AppleMediaNegotiating = AppleMediaNegotiator(),
        videoStreamStarter: any AppleVideoStreamStarting = AppleVideoStreamStarter(),
        credentialStore: any CredentialStoring = KeychainCredentialStore(),
        resolutionPreferences: MobileResolutionPreferences = MobileResolutionPreferences()
    ) {
        self.endpoint = endpoint
        self.authenticator = authenticator
        self.controlChannelNegotiator = controlChannelNegotiator
        self.mediaNegotiator = mediaNegotiator
        self.videoStreamStarter = videoStreamStarter
        self.credentialStore = credentialStore
        self.resolutionPreferences = resolutionPreferences
    }

    func savedCredentials(preferredUsername: String = "") async -> ScreenSharingCredentials? {
        let credentialStore = credentialStore
        let endpoint = endpoint
        let credentials = await Task.detached {
            try? credentialStore.load(for: endpoint)
        }.value
        guard !Task.isCancelled, let credentials else { return nil }
        let preferred = preferredUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard preferred.isEmpty || preferred == credentials.username else { return nil }
        return credentials
    }

    func connect(username: String, password: String, rememberPassword: Bool = false) {
        guard state != .connecting else { return }
        state = .connecting
        connectionTask = Task { [weak self] in
            await self?.establishSession(
                username: username,
                password: password,
                rememberPassword: rememberPassword
            )
        }
    }

    private func establishSession(
        username: String,
        password: String,
        rememberPassword: Bool
    ) async {
        var connectingSession: RFBAuthenticatedSession?
        do {
            let credentials = try ScreenSharingCredentials(username: username, password: password)
            let session = try await authenticator.connect(
                to: endpoint,
                credentials: credentials,
                sharingType: .highPerformance
            )
            connectingSession = session
            let requestedPreset = resolutionPreferences.preset(for: endpoint)
            let requestedSize = requestedPreset.size(for: viewportSize ?? .zero)
                ?? AppleDynamicResolutionSize(width: 1440, height: 900)
            _ = try await controlChannelNegotiator.enableEncryption(
                for: session,
                displaySizes: [requestedSize]
            )
            let negotiation = try await mediaNegotiator.negotiate(session, displayCount: 1)
            let input = AppleInputController(session: session, canvas: negotiation.canvas)
            session.install(inputController: input)

            let clipboard = MobileClipboardService(
                advertise: { [weak input] archive in
                    guard let input else { throw CancellationError() }
                    try await input.sendClipboard(archive, promises: true)
                },
                updateRemoteSharingEnabled: { [weak input] enabled in
                    if enabled {
                        await input?.enableClipboard()
                    } else {
                        await input?.disableClipboard()
                    }
                }
            )
            let cursors = AppleCursorStore()
            session.install(cursorStore: cursors)

            try videoStreamStarter.startVideo(
                for: session, negotiation: negotiation, decoderMode: .videoToolboxSynchronized
            )
            guard let stream = session.videoStream as? AppleVideoStream else {
                throw AppleVideoStreamError.missingMediaReceiver
            }
            self.session = session
            observe(stream, session: session)
            let dynamicResolutionController = AppleDynamicResolutionController(
                initialCanvas: negotiation.canvas,
                mediaConfiguration: negotiation.configuration,
                sendMessage: { [weak session] message in
                    guard let session else { throw CancellationError() }
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
            session.install(dynamicResolutionController: dynamicResolutionController)
            session.install(dynamicResolutionModel: AppleDynamicResolutionModel())

            let controlMessages = AppleControlMessageService(
                session: session,
                input: input,
                clipboard: clipboard,
                pendingMessages: negotiation.pendingMessages,
                receiveDisplayLayout: { layout in
                    try? await dynamicResolutionController.receive(layout)
                },
                receiveMediaCanvas: { canvas in
                    await dynamicResolutionController.receiveMediaCanvas(canvas)
                },
                receiveCursorUpdate: { update in cursors.apply(update) },
                receiveDeviceInfo: { [weak self, weak session] info in
                    await MainActor.run { [weak self, weak session] in
                        guard let self, let session, self.session === session else { return }
                        self.deviceInfo = info
                    }
                },
                didFail: { [weak self, weak session] message in
                    self?.connectionDidFail(message, session: session)
                }
            )
            session.install(controlMessageService: controlMessages, clipboardService: clipboard)
            session.install(controlState: AppleSessionControlState(session: session))
            try await session.sendEncrypted(AppleRFBMessages.controlMode(observing: false))
            configureAudio(for: session, negotiation: negotiation)
            clipboard.start()
            clipboard.setActive(isActive)
            try Task.checkCancellation()
            guard self.session === session else { return }
            selectedResolutionPreset = requestedPreset
            state = .connected
            connectionTask = nil
            controlMessages.start()
            persist(credentials, remember: rememberPassword)
        } catch is CancellationError {
            connectingSession?.close()
            if session === connectingSession { session = nil }
            deactivateAudioSession()
            state = .idle
            connectionTask = nil
        } catch {
            connectingSession?.close()
            if session === connectingSession { session = nil }
            deactivateAudioSession()
            state = .failed(error.localizedDescription)
            connectionTask = nil
        }
    }

    func disconnect() {
        connectionTask?.cancel()
        connectionTask = nil
        resolutionTask?.cancel()
        resolutionTask = nil
        streamStateObserver = nil
        (session?.clipboardService as? MobileClipboardService)?.setActive(false)
        session?.close()
        session = nil
        state = .idle
        selectedResolutionPreset = nil
        resolutionErrorMessage = nil
        deactivateAudioSession()
    }

    func setActive(_ active: Bool) {
        isActive = active
        (session?.clipboardService as? MobileClipboardService)?.setActive(active)
    }

    func updateViewport(_ size: CGSize) {
        guard size.width > 0, size.height > 0, viewportSize != size else { return }
        viewportSize = size
    }

    func requestResolution(_ preset: MobileResolutionPreset) {
        guard let session,
              let controller = session.dynamicResolutionController,
              let size = preset.size(for: viewportSize ?? .zero) else { return }
        resolutionTask?.cancel()
        resolutionTask = Task { [weak self, weak session] in
            do {
                try await controller.request(displaySizes: [size])
                try Task.checkCancellation()
                guard let self, let session, self.session === session else { return }
                selectedResolutionPreset = preset
                resolutionPreferences.save(preset, for: endpoint)
                resolutionErrorMessage = nil
                resolutionTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                guard let self, let session, self.session === session else { return }
                resolutionErrorMessage = error.localizedDescription
                resolutionTask = nil
            }
        }
    }

    func clearResolutionError() {
        resolutionErrorMessage = nil
    }

    private func observe(_ stream: AppleVideoStream, session: RFBAuthenticatedSession) {
        streamStateObserver = stream.$state.sink { [weak self, weak session] state in
            guard case .failed(let message) = state else { return }
            self?.connectionDidFail(message, session: session)
        }
    }

    private func connectionDidFail(_ message: String, session failedSession: RFBAuthenticatedSession?) {
        guard let failedSession, session === failedSession else { return }
        resolutionTask?.cancel()
        resolutionTask = nil
        streamStateObserver = nil
        failedSession.close()
        session = nil
        selectedResolutionPreset = nil
        resolutionErrorMessage = nil
        deactivateAudioSession()
        state = .failed(message)
    }

    private func configureAudio(
        for session: RFBAuthenticatedSession,
        negotiation: AppleMediaNegotiationResult
    ) {
        guard let receiver = session.mediaReceiver else { return }
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default)
            try audioSession.setActive(true)
            let audio = try AppleAudioStream(receiver: receiver, negotiation: negotiation)
            session.install(audioStream: audio)
            audio.start()
        } catch {
            // Video and control remain usable when audio is unavailable.
        }
    }

    private func persist(_ credentials: ScreenSharingCredentials, remember: Bool) {
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

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }
}
