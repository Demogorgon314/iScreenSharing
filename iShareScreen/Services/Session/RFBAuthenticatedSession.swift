import Foundation

final class RFBAuthenticatedSession: @unchecked Sendable {
    let endpoint: ConnectionEndpoint
    let remoteAddress: ResolvedRemoteAddress
    let serverVersion: RFBVersion
    let securityTypes: [RFBSecurityType]
    let masterKey: Data
    let serverInfo: RFBServerInfo
    private(set) var recordLayer: AppleEncryptedRecordLayer?
    private(set) var rekeyGeneration: UInt32?
    private(set) var mediaNegotiation: AppleMediaNegotiationResult?
    private(set) var mediaReceiver: AppleMediaReceiver?
    private(set) var videoStreams = [AppleVideoStream]()
    var videoStream: AppleVideoStream? {
        videoStreams.first(where: { $0.displayIndex == 0 }) ?? videoStreams.first
    }
    private(set) var inputController: AppleInputController?
    private(set) var controlMessageService: AppleControlMessageService?
    private(set) var clipboardService: AppleClipboardService?
    private(set) var audioStream: AppleAudioStream?
    private(set) var dynamicResolutionController: AppleDynamicResolutionController?
    private(set) var cursorStore: AppleCursorStore?
    private(set) var displayLayoutModel: AppleDisplayLayoutModel?
    private(set) var dynamicResolutionModel: AppleDynamicResolutionModel?

    private let transport: NWConnectionTransport

    init(
        endpoint: ConnectionEndpoint,
        remoteAddress: ResolvedRemoteAddress,
        serverVersion: RFBVersion,
        securityTypes: [RFBSecurityType],
        masterKey: Data,
        serverInfo: RFBServerInfo,
        transport: NWConnectionTransport
    ) {
        self.endpoint = endpoint
        self.remoteAddress = remoteAddress
        self.serverVersion = serverVersion
        self.securityTypes = securityTypes
        self.masterKey = masterKey
        self.serverInfo = serverInfo
        self.transport = transport
    }

    func close() {
        controlMessageService?.close()
        audioStream?.close()
        if let inputController { Task { await inputController.close() } }
        videoStreams.forEach { $0.close() }
        mediaReceiver?.close()
        transport.cancel()
    }

    func send(_ data: Data) async throws {
        try await transport.send(data)
    }

    func receiveExactly(_ length: Int) async throws -> Data {
        try await transport.receiveExactly(length)
    }

    func install(recordLayer: AppleEncryptedRecordLayer, generation: UInt32) {
        self.recordLayer = recordLayer
        rekeyGeneration = generation
    }

    func sendEncrypted(_ message: Data) async throws {
        try await sendEncrypted([message])
    }

    func sendEncrypted(_ messages: [Data]) async throws {
        guard let recordLayer else { throw RFBSessionError.encryptionNotEnabled }
        try await send(try recordLayer.encrypt(messages))
    }

    func receiveEncrypted() async throws -> Data {
        guard let recordLayer else { throw RFBSessionError.encryptionNotEnabled }
        let header = try await receiveExactly(2)
        let length = try Int(header.uint16BE(at: 0))
        guard length > 0, length.isMultiple(of: 16) else {
            throw AppleEncryptedRecordError.invalidCiphertext
        }
        return try recordLayer.decrypt(try await receiveExactly(length))
    }

    func install(mediaNegotiation: AppleMediaNegotiationResult) {
        self.mediaNegotiation = mediaNegotiation
    }

    func install(mediaReceiver: AppleMediaReceiver) {
        self.mediaReceiver?.close()
        self.mediaReceiver = mediaReceiver
    }

    func install(videoStream: AppleVideoStream) {
        install(videoStreams: [videoStream])
    }

    func install(videoStreams: [AppleVideoStream]) {
        self.videoStreams.forEach { $0.close() }
        self.videoStreams = videoStreams
    }

    func videoStream(for displayIndex: Int) -> AppleVideoStream? {
        videoStreams.first(where: { $0.displayIndex == displayIndex }) ?? videoStream
    }

    func install(inputController: AppleInputController) {
        if let current = self.inputController { Task { await current.close() } }
        self.inputController = inputController
    }

    func install(
        controlMessageService: AppleControlMessageService,
        clipboardService: AppleClipboardService
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

    deinit {
        controlMessageService?.close()
        audioStream?.close()
        if let inputController { Task { await inputController.close() } }
        videoStreams.forEach { $0.close() }
        mediaReceiver?.close()
        transport.cancel()
    }
}

enum RFBSessionError: LocalizedError {
    case encryptionNotEnabled

    var errorDescription: String? { "The encrypted Screen Sharing channel is not ready." }
}
