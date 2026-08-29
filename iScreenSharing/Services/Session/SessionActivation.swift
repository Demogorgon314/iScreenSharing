import Foundation
import struct ScreenSharingProtocol.AppleCanvas
import struct ScreenSharingProtocol.AppleDynamicResolutionSize

struct SessionActivationConfiguration {
    let sharingType: ScreenSharingType
    let standardQuality: StandardRFBQuality
    let virtualDisplayCount: VirtualDisplayCount
    let requestedDisplaySizes: [AppleDynamicResolutionSize]
}

enum SessionActivationError: LocalizedError, Equatable {
    case invalidDisplayConfiguration(expectedCount: Int, actualCount: Int)
    case sharingTypeMismatch(expected: ScreenSharingType, actual: ScreenSharingType)

    var errorDescription: String? {
        switch self {
        case let .invalidDisplayConfiguration(expectedCount, actualCount):
            "The session requested \(expectedCount) displays but provided \(actualCount) display sizes."
        case let .sharingTypeMismatch(expected, actual):
            "The authenticated session mode \(actual) does not match the requested mode \(expected)."
        }
    }
}

@MainActor
protocol SessionActivating {
    /// Owns any authenticated session until activation either fails closed or returns ownership
    /// of a ready session to the caller.
    func activate(
        endpoint: ConnectionEndpoint,
        credentials: ScreenSharingCredentials,
        configuration: SessionActivationConfiguration
    ) async throws -> RFBAuthenticatedSession
}

@MainActor
final class SessionActivation: SessionActivating {
    private let authenticator: any RFBAuthenticating
    private let controlChannelNegotiator: any AppleControlChannelNegotiating
    private let mediaNegotiator: any AppleMediaNegotiating
    private let videoStreamStarter: any AppleVideoStreamStarting
    private let connectionStore: ConnectionStore
    private let sessionFeaturePreferences: SessionFeaturePreferences

    init(
        authenticator: any RFBAuthenticating = RFBAuthenticationService(),
        controlChannelNegotiator: any AppleControlChannelNegotiating = AppleControlChannelNegotiator(),
        mediaNegotiator: any AppleMediaNegotiating = AppleMediaNegotiator(),
        videoStreamStarter: any AppleVideoStreamStarting = AppleVideoStreamStarter(),
        connectionStore: ConnectionStore,
        sessionFeaturePreferences: SessionFeaturePreferences = SessionFeaturePreferences()
    ) {
        self.authenticator = authenticator
        self.controlChannelNegotiator = controlChannelNegotiator
        self.mediaNegotiator = mediaNegotiator
        self.videoStreamStarter = videoStreamStarter
        self.connectionStore = connectionStore
        self.sessionFeaturePreferences = sessionFeaturePreferences
    }

    func activate(
        endpoint: ConnectionEndpoint,
        credentials: ScreenSharingCredentials,
        configuration: SessionActivationConfiguration
    ) async throws -> RFBAuthenticatedSession {
        if configuration.sharingType == .highPerformance,
           configuration.requestedDisplaySizes.count
            != configuration.virtualDisplayCount.rawValue {
            throw SessionActivationError.invalidDisplayConfiguration(
                expectedCount: configuration.virtualDisplayCount.rawValue,
                actualCount: configuration.requestedDisplaySizes.count
            )
        }
        var pendingSession: RFBAuthenticatedSession?
        do {
            let session = try await authenticator.connect(
                to: endpoint,
                credentials: credentials,
                sharingType: configuration.sharingType
            )
            pendingSession = session
            try Task.checkCancellation()
            guard session.sharingType == configuration.sharingType else {
                throw SessionActivationError.sharingTypeMismatch(
                    expected: configuration.sharingType,
                    actual: session.sharingType
                )
            }

            switch configuration.sharingType {
            case .standard:
                try await activateStandard(
                    session,
                    quality: configuration.standardQuality
                )
            case .highPerformance:
                try await activateHighPerformance(
                    session,
                    endpoint: endpoint,
                    configuration: configuration
                )
            }

            try Task.checkCancellation()
            pendingSession = nil
            return session
        } catch {
            pendingSession?.close()
            throw error
        }
    }

    private func activateStandard(
        _ session: RFBAuthenticatedSession,
        quality: StandardRFBQuality
    ) async throws {
        let stream = try StandardRFBVideoStream(session: session, quality: quality)
        session.install(videoStream: stream)
        let input = AppleInputController(session: session, canvas: stream.canvas)
        session.install(inputController: input)
        session.install(cursorStore: AppleCursorStore())
        session.install(displayLayoutModel: AppleDisplayLayoutModel())
        session.install(dynamicResolutionModel: AppleDynamicResolutionModel(isEnabled: false))
        session.install(controlState: AppleSessionControlState(session: session))
        stream.start()
        try await stream.waitForFirstFrame()
    }

    private func activateHighPerformance(
        _ session: RFBAuthenticatedSession,
        endpoint: ConnectionEndpoint,
        configuration: SessionActivationConfiguration
    ) async throws {
        _ = try await controlChannelNegotiator.enableEncryption(
            for: session,
            displaySizes: configuration.requestedDisplaySizes
        )
        let negotiation = try await mediaNegotiator.negotiate(
            session,
            displayCount: configuration.virtualDisplayCount.rawValue
        )
        let input = AppleInputController(session: session, canvas: negotiation.canvas)
        session.install(inputController: input)
        let clipboard = AppleClipboardService(
            isSharingEnabled: session.serverInfo.supportsSharedPasteboard,
            supportsSharedClipboard: session.serverInfo.supportsSharedPasteboard,
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
        let fileTransferService: AppleFileTransferService?
        let fileCopySender = AppleSystemFileCopySender()
        if session.serverInfo.supportsViewerToHostFileTransfer,
           fileCopySender.isAvailable {
            let history = AppleFileTransferHistory()
            let service = AppleFileTransferService(
                remoteName: session.serverInfo.name,
                history: history,
                sender: fileCopySender,
                send: { [weak session] messages in
                    guard let session else { throw CancellationError() }
                    try await session.sendEncrypted(messages)
                }
            )
            session.install(fileTransferService: service)
            fileTransferService = service
        } else {
            fileTransferService = nil
        }
        try videoStreamStarter.startVideo(for: session, negotiation: negotiation)
        let dynamicResolutionController: AppleDynamicResolutionController?
        if configuration.virtualDisplayCount == .one,
           let stream = session.videoStream as? AppleVideoStream {
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
            expectedDisplayCount: configuration.virtualDisplayCount.rawValue
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
            displayCount: configuration.virtualDisplayCount.rawValue,
            isEnabled: sessionFeaturePreferences.usesDynamicResolution,
            didChangeEnabled: sessionFeaturePreferences.setUsesDynamicResolution,
            requestFixedResolution: {
                try await dynamicResolutionController?.requestFixedResolution()
            }
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
            receiveDeviceInfo: { [connectionStore, endpoint] info in
                await MainActor.run {
                    connectionStore.record(endpoint, deviceInfo: info)
                }
            },
            receiveFileTransferMessage: { [weak fileTransferService] message in
                await fileTransferService?.receive(message) ?? false
            }
        )
        session.install(
            controlMessageService: controlMessages,
            clipboardService: clipboard
        )
        session.install(controlState: AppleSessionControlState(session: session))
        clipboard.start()
        controlMessages.start()
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
    }
}
