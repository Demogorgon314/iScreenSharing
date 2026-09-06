import Foundation
import enum ScreenSharingProtocol.AppleClipboardMessage
import enum ScreenSharingProtocol.AppleEncryptedRecordError
import class ScreenSharingProtocol.AppleEncryptedRecordLayer
import struct ScreenSharingProtocol.RFBServerInfo

final class RFBAuthenticatedSession: @unchecked Sendable {
    let endpoint: ConnectionEndpoint
    let remoteAddress: ResolvedRemoteAddress
    let sharingType: ScreenSharingType
    let masterKey: Data
    let serverInfo: RFBServerInfo
    let connectionTiming: ConnectionStartupTrace?
    private(set) var recordLayer: AppleEncryptedRecordLayer?
    private(set) var mediaReceiver: (any AppleMediaReceiving)?
    private(set) var videoStreams = [SessionVideoStream]()
    var videoStream: SessionVideoStream? {
        videoStreams.first(where: { $0.displayIndex == 0 }) ?? videoStreams.first
    }
    private(set) var inputController: AppleInputController?
    private(set) var controlMessageService: AppleControlMessageService?
    private(set) var clipboardService: (any AppleClipboardReceiving)?
    private(set) var audioStream: AppleAudioStream?
    private(set) var dynamicResolutionController: AppleDynamicResolutionController?
    private(set) var cursorStore: AppleCursorStore?
    private(set) var displayLayoutModel: AppleDisplayLayoutModel?
    private(set) var dynamicResolutionModel: AppleDynamicResolutionModel?
    private(set) var remoteSystemCapabilities: AppleRemoteSystemCapabilities?
#if os(macOS)
    private(set) var keyboardInputSourceService: AppleKeyboardInputSourceService?
    private(set) var fileTransferService: AppleFileTransferService?
#endif
    private(set) var controlState: AppleSessionControlState?

    private let route: any OpenSessionRoute
    private var transport: any RFBTransport { route.control }
    private let encryptedWriter: AppleEncryptedRecordWriter
    private let standardWriter: RFBStandardWriter
    private let closeLock = NSLock()
    private var hasClosed = false
    private var terminationHandler: (@Sendable () -> Void)?

    init(
        endpoint: ConnectionEndpoint,
        sharingType: ScreenSharingType = .highPerformance,
        masterKey: Data,
        serverInfo: RFBServerInfo,
        route: any OpenSessionRoute,
        connectionTiming: ConnectionStartupTrace? = ConnectionStartupTrace.current
    ) {
        self.endpoint = endpoint
        remoteAddress = route.remoteAddress
        self.sharingType = sharingType
        self.masterKey = masterKey
        self.serverInfo = serverInfo
        self.route = route
        self.connectionTiming = connectionTiming
        let transport = route.control
        encryptedWriter = AppleEncryptedRecordWriter { data in
            try await transport.send(data)
        }
        standardWriter = RFBStandardWriter { data in
            try await transport.send(data)
        }
    }

    convenience init(
        endpoint: ConnectionEndpoint,
        remoteAddress: ResolvedRemoteAddress,
        sharingType: ScreenSharingType = .highPerformance,
        masterKey: Data,
        serverInfo: RFBServerInfo,
        transport: any RFBTransport
    ) {
        self.init(
            endpoint: endpoint,
            sharingType: sharingType,
            masterKey: masterKey,
            serverInfo: serverInfo,
            route: ManagedSessionRoute(
                control: transport,
                remoteAddress: remoteAddress,
                sharingType: sharingType
            ) { address, displayCount in
                try AppleMediaReceiver(
                    remoteAddress: address,
                    displayCount: displayCount
                )
            }
        )
    }

    /// Interrupts route I/O while activation still owns the session. Activation
    /// must then call close() to clean up its partially installed resources.
    func cancelPendingActivation() {
        route.close()
    }

    func close() {
        closeLock.lock()
        guard !hasClosed else {
            closeLock.unlock()
            return
        }
        hasClosed = true
        let terminationHandler = terminationHandler
        self.terminationHandler = nil
        closeLock.unlock()

        connectionTiming?.finish(.closed)
        controlMessageService?.close()
        audioStream?.close()
        videoStreams.forEach { $0.close() }
        mediaReceiver?.close()
        let clipboardService = clipboardService
#if os(macOS)
        let keyboardInputSourceService = keyboardInputSourceService
        let fileTransferService = fileTransferService
#endif
        let inputController = inputController
        let recordLayer = recordLayer
        let encryptedWriter = encryptedWriter
        let route = route
        terminationHandler?()
        Task { @MainActor in
            clipboardService?.close()
#if os(macOS)
            keyboardInputSourceService?.close()
            await fileTransferService?.close()
#endif
            if let recordLayer {
                try? await encryptedWriter.send(
                    [AppleClipboardMessage.disable],
                    using: recordLayer
                )
            }
            await inputController?.close()
            route.close()
        }
    }

    func setTerminationHandler(_ handler: @escaping @Sendable () -> Void) {
        closeLock.lock()
        if hasClosed {
            closeLock.unlock()
            handler()
            return
        }
        terminationHandler = handler
        closeLock.unlock()
    }

    func openHighPerformanceMedia(
        displayCount: Int
    ) async throws -> any AppleMediaReceiving {
        try await route.openHighPerformanceMedia(displayCount: displayCount)
    }

    func send(_ data: Data) async throws {
        try await transport.send(data)
    }

    func sendStandard(_ data: Data) async throws {
        try await sendStandard([data])
    }

    func sendStandard(_ messages: [Data]) async throws {
        try await standardWriter.send(messages)
    }

    func receiveExactly(_ length: Int) async throws -> Data {
        try await transport.receiveExactly(length)
    }

    func install(recordLayer: AppleEncryptedRecordLayer) {
        self.recordLayer = recordLayer
    }

    func sendEncrypted(_ message: Data) async throws {
        try await sendEncrypted([message])
    }

    func sendEncrypted(_ messages: [Data]) async throws {
        guard let recordLayer else { throw RFBSessionError.encryptionNotEnabled }
        try await encryptedWriter.send(messages, using: recordLayer)
    }

    func receiveEncrypted(
        startupTiming: ConnectionStartupTrace.MediaResponse? = nil
    ) async throws -> Data {
        guard let recordLayer else { throw RFBSessionError.encryptionNotEnabled }
        let header = try await receiveExactly(2)
        startupTiming?.record(.mediaHeaderReceived, since: .mediaReadStarted)
        let length = try Int(header.uint16BE(at: 0))
        guard length > 0, length.isMultiple(of: 16) else {
            throw AppleEncryptedRecordError.invalidCiphertext
        }
        let ciphertext = try await receiveExactly(length)
        startupTiming?.record(.mediaBodyReceived, since: .mediaHeaderReceived, count: ciphertext.count)
        let message = try recordLayer.decrypt(ciphertext)
        startupTiming?.record(.mediaRecordDecrypted, since: .mediaBodyReceived, count: message.count)
        return message
    }

    func install(mediaReceiver: any AppleMediaReceiving) {
        self.mediaReceiver?.close()
        self.mediaReceiver = mediaReceiver
    }

    func install(videoStream: SessionVideoStream) {
        install(videoStreams: [videoStream])
    }

    func install(videoStreams: [SessionVideoStream]) {
        self.videoStreams.forEach { $0.close() }
        self.videoStreams = videoStreams
    }

    func videoStream(for displayIndex: Int) -> SessionVideoStream? {
        videoStreams.first(where: { $0.displayIndex == displayIndex }) ?? videoStream
    }

    func setVideoDecoderMode(_ mode: AppleVideoDecoderMode) {
        videoStreams.forEach { $0.setDecoderMode(mode) }
    }

    func install(inputController: AppleInputController) {
        if let current = self.inputController { Task { await current.close() } }
        self.inputController = inputController
    }

    func install(
        controlMessageService: AppleControlMessageService,
        clipboardService: any AppleClipboardReceiving
    ) {
        self.controlMessageService?.close()
        self.controlMessageService = controlMessageService
        self.clipboardService = clipboardService
    }

    func install(audioStream: AppleAudioStream) {
        self.audioStream?.close()
        self.audioStream = audioStream
    }

    func install(dynamicResolutionController: AppleDynamicResolutionController) {
        self.dynamicResolutionController = dynamicResolutionController
    }

    func install(cursorStore: AppleCursorStore) {
        self.cursorStore = cursorStore
    }

    @MainActor
    func install(displayLayoutModel: AppleDisplayLayoutModel) {
        self.displayLayoutModel = displayLayoutModel
    }

    @MainActor
    func install(dynamicResolutionModel: AppleDynamicResolutionModel) {
        self.dynamicResolutionModel = dynamicResolutionModel
    }

    @MainActor
    func install(remoteSystemCapabilities: AppleRemoteSystemCapabilities) {
        self.remoteSystemCapabilities = remoteSystemCapabilities
    }

#if os(macOS)
    @MainActor
    func install(keyboardInputSourceService: AppleKeyboardInputSourceService) {
        self.keyboardInputSourceService?.close()
        self.keyboardInputSourceService = keyboardInputSourceService
    }

    func install(fileTransferService: AppleFileTransferService) {
        self.fileTransferService = fileTransferService
    }
#endif

    @MainActor
    func install(controlState: AppleSessionControlState) {
        self.controlState = controlState
    }

    deinit {
        close()
    }
}

actor RFBStandardWriter {
    typealias Send = @Sendable (Data) async throws -> Void

    private let sendData: Send
    private var tail = Task<Void, Never> { }
    private var hasTerminalFailure = false

    init(send: @escaping Send) {
        sendData = send
    }

    func send(_ messages: [Data]) async throws {
        let predecessor = tail
        let request = Task { [weak self] in
            await predecessor.value
            guard let self else { throw AppleEncryptedRecordWriterError.closed }
            try await self.sendInOrder(messages)
        }
        tail = Task { _ = await request.result }
        try await request.value
    }

    private func sendInOrder(_ messages: [Data]) async throws {
        guard !hasTerminalFailure else {
            throw AppleEncryptedRecordWriterError.transportFailed
        }
        do {
            for message in messages {
                try await sendData(message)
            }
        } catch {
            hasTerminalFailure = true
            throw error
        }
    }
}

actor AppleEncryptedRecordWriter {
    typealias Send = @Sendable (Data) async throws -> Void

    private let sendRecord: Send
    private var tail = Task<Void, Never> {}
    private var hasTerminalFailure = false

    init(send: @escaping Send) {
        sendRecord = send
    }

    func send(_ messages: [Data], using recordLayer: AppleEncryptedRecordLayer) async throws {
        let predecessor = tail
        let request = Task { [weak self] in
            await predecessor.value
            guard let self else { throw AppleEncryptedRecordWriterError.closed }
            try await self.encryptAndSend(messages, using: recordLayer)
        }
        tail = Task { _ = await request.result }
        try await request.value
    }

    private func encryptAndSend(
        _ messages: [Data],
        using recordLayer: AppleEncryptedRecordLayer
    ) async throws {
        guard !hasTerminalFailure else {
            throw AppleEncryptedRecordWriterError.transportFailed
        }
        let record = try recordLayer.encrypt(messages)
        do {
            try await sendRecord(record)
        } catch {
            hasTerminalFailure = true
            throw error
        }
    }
}

enum AppleEncryptedRecordWriterError: LocalizedError, Equatable {
    case closed
    case transportFailed

    var errorDescription: String? {
        switch self {
        case .closed: "The encrypted Screen Sharing writer is closed."
        case .transportFailed: "The encrypted Screen Sharing connection can no longer send data."
        }
    }
}

enum RFBSessionError: LocalizedError {
    case encryptionNotEnabled

    var errorDescription: String? { "The encrypted Screen Sharing channel is not ready." }
}
