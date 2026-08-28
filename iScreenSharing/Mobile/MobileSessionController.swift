import AVFAudio
import Combine
import Foundation

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

    let endpoint: ConnectionEndpoint

    private let authenticator: any RFBAuthenticating
    private let controlChannelNegotiator: any AppleControlChannelNegotiating
    private let mediaNegotiator: any AppleMediaNegotiating
    private let videoStreamStarter: any AppleVideoStreamStarting
    private var isActive = true
    private var streamStateObserver: AnyCancellable?
    private var connectionTask: Task<Void, Never>?

    init(
        endpoint: ConnectionEndpoint,
        authenticator: any RFBAuthenticating = RFBAuthenticationService(),
        controlChannelNegotiator: any AppleControlChannelNegotiating = AppleControlChannelNegotiator(),
        mediaNegotiator: any AppleMediaNegotiating = AppleMediaNegotiator(),
        videoStreamStarter: any AppleVideoStreamStarting = AppleVideoStreamStarter()
    ) {
        self.endpoint = endpoint
        self.authenticator = authenticator
        self.controlChannelNegotiator = controlChannelNegotiator
        self.mediaNegotiator = mediaNegotiator
        self.videoStreamStarter = videoStreamStarter
    }

    func connect(username: String, password: String) {
        guard state != .connecting else { return }
        state = .connecting
        connectionTask = Task { [weak self] in
            await self?.establishSession(username: username, password: password)
        }
    }

    private func establishSession(username: String, password: String) async {
        var connectingSession: RFBAuthenticatedSession?
        do {
            let credentials = try ScreenSharingCredentials(username: username, password: password)
            let session = try await authenticator.connect(to: endpoint, credentials: credentials)
            connectingSession = session
            _ = try await controlChannelNegotiator.enableEncryption(
                for: session,
                displaySizes: [.fixed1080p]
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

            let controlMessages = AppleControlMessageService(
                session: session,
                input: input,
                clipboard: clipboard,
                pendingMessages: negotiation.pendingMessages,
                receiveCursorUpdate: { update in cursors.apply(update) },
                didFail: { [weak self, weak session] message in
                    self?.connectionDidFail(message, session: session)
                }
            )
            session.install(controlMessageService: controlMessages, clipboardService: clipboard)
            session.install(controlState: AppleSessionControlState(session: session))

            try videoStreamStarter.startVideo(for: session, negotiation: negotiation)
            session.setVideoDecoderMode(.videoToolboxSynchronized)
            self.session = session
            if let stream = session.videoStream { observe(stream, session: session) }
            configureAudio(for: session, negotiation: negotiation)
            clipboard.start()
            clipboard.setActive(isActive)
            try Task.checkCancellation()
            guard self.session === session else { return }
            state = .connected
            connectionTask = nil
            controlMessages.start()
        } catch is CancellationError {
            connectingSession?.close()
            if session === connectingSession { session = nil }
            state = .idle
            connectionTask = nil
        } catch {
            connectingSession?.close()
            if session === connectingSession { session = nil }
            state = .failed(error.localizedDescription)
            connectionTask = nil
        }
    }

    func disconnect() {
        connectionTask?.cancel()
        connectionTask = nil
        streamStateObserver = nil
        (session?.clipboardService as? MobileClipboardService)?.setActive(false)
        session?.close()
        session = nil
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func setActive(_ active: Bool) {
        isActive = active
        (session?.clipboardService as? MobileClipboardService)?.setActive(active)
    }

    private func observe(_ stream: AppleVideoStream, session: RFBAuthenticatedSession) {
        streamStateObserver = stream.$state.sink { [weak self, weak session] state in
            guard case .failed(let message) = state else { return }
            self?.connectionDidFail(message, session: session)
        }
    }

    private func connectionDidFail(_ message: String, session failedSession: RFBAuthenticatedSession?) {
        guard let failedSession, session === failedSession else { return }
        streamStateObserver = nil
        failedSession.close()
        session = nil
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
}
