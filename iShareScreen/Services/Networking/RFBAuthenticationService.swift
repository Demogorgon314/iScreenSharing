import Foundation

final class RFBAuthenticatedSession: @unchecked Sendable {
    let endpoint: ConnectionEndpoint
    let serverVersion: RFBVersion
    let securityTypes: [RFBSecurityType]
    let masterKey: Data
    let serverInfo: RFBServerInfo
    private(set) var recordLayer: AppleEncryptedRecordLayer?
    private(set) var rekeyGeneration: UInt32?
    private(set) var mediaNegotiation: AppleMediaNegotiationResult?
    private(set) var mediaReceiver: AppleMediaReceiver?
    private(set) var videoStream: AppleVideoStream?
    private(set) var inputController: AppleInputController?
    private(set) var controlMessageService: AppleControlMessageService?
    private(set) var clipboardService: AppleClipboardService?
    private(set) var audioStream: AppleAudioStream?

    private let transport: NWConnectionTransport

    init(
        endpoint: ConnectionEndpoint,
        serverVersion: RFBVersion,
        securityTypes: [RFBSecurityType],
        masterKey: Data,
        serverInfo: RFBServerInfo,
        transport: NWConnectionTransport
    ) {
        self.endpoint = endpoint
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
        videoStream?.close()
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
        guard let recordLayer else { throw RFBSessionError.encryptionNotEnabled }
        try await send(try recordLayer.encrypt(message))
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
        self.videoStream?.close()
        self.videoStream = videoStream
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

    deinit {
        controlMessageService?.close()
        audioStream?.close()
        if let inputController { Task { await inputController.close() } }
        videoStream?.close()
        mediaReceiver?.close()
        transport.cancel()
    }
}

enum RFBSessionError: LocalizedError {
    case encryptionNotEnabled

    var errorDescription: String? { "The encrypted Screen Sharing channel is not ready." }
}

protocol RFBAuthenticating: Sendable {
    func connect(
        to endpoint: ConnectionEndpoint,
        credentials: ScreenSharingCredentials
    ) async throws -> RFBAuthenticatedSession
}

struct RFBAuthenticationService: RFBAuthenticating {
    private static let maximumPublicKeyPacketLength = 64 * 1024
    private static let maximumServerNameLength = 1024 * 1024

    func connect(
        to endpoint: ConnectionEndpoint,
        credentials: ScreenSharingCredentials
    ) async throws -> RFBAuthenticatedSession {
        let transport = NWConnectionTransport(endpoint: endpoint)
        do {
            try await transport.start()
            let probe = try await performVersionHandshake(on: transport)
            guard probe.securityTypes.contains(.appleRSA) else {
                throw AppleRSA1Error.unsupportedServer
            }

            let masterKey = try await authenticateRSA1(
                credentials: credentials,
                transport: transport
            )
            let serverInfo = try await initializeSession(on: transport)
            return RFBAuthenticatedSession(
                endpoint: endpoint,
                serverVersion: probe.serverVersion,
                securityTypes: probe.securityTypes,
                masterKey: masterKey,
                serverInfo: serverInfo,
                transport: transport
            )
        } catch {
            transport.cancel()
            throw error
        }
    }

    private func performVersionHandshake(
        on transport: NWConnectionTransport
    ) async throws -> RFBProbeResult {
        let banner = try await transport.receiveExactly(RFBProtocol.bannerLength)
        let version = try RFBProtocol.parseVersion(banner)
        try await transport.send(RFBProtocol.appleVersion)
        let count = try RFBProtocol.parseSecurityTypeCount(
            try await transport.receiveExactly(1)
        )
        let types = try RFBProtocol.parseSecurityTypes(
            try await transport.receiveExactly(count),
            expectedCount: count
        )
        return RFBProbeResult(serverVersion: version, securityTypes: types)
    }

    private func authenticateRSA1(
        credentials: ScreenSharingCredentials,
        transport: NWConnectionTransport
    ) async throws -> Data {
        try await transport.send(AppleRSA1.publicKeyRequest)
        let packetLengthData = try await transport.receiveExactly(4)
        let packetLength = try Int(packetLengthData.uint32BE(at: 0))
        guard packetLength > 0, packetLength <= Self.maximumPublicKeyPacketLength else {
            throw AppleRSA1Error.invalidPublicKeyResponse
        }
        let packet = try await transport.receiveExactly(packetLength)
        let subjectPublicKeyInfo = try AppleRSA1.parsePublicKeyResponse(packet)
        let publicKey = try Cryptography.makeRSAPublicKey(subjectPublicKeyInfo: subjectPublicKeyInfo)

        let masterKey = try Cryptography.randomBytes(count: 16)
        let plaintext = try AppleRSA1.credentialPlaintext(
            username: credentials.username,
            password: credentials.password,
            randomBytes: Cryptography.randomBytes(count:)
        )
        let encryptedCredentials = try Cryptography.encryptAESECB(plaintext, key: masterKey)
        let encryptedKey = try Cryptography.encryptRSA(masterKey, publicKey: publicKey)
        let request = try AppleRSA1.authenticationRequest(
            encryptedCredentials: encryptedCredentials,
            encryptedAESKey: encryptedKey
        )
        try await transport.send(request)

        _ = try await transport.receiveExactly(4)
        try AppleRSA1.parseSecurityResult(try await transport.receiveExactly(4))
        return masterKey
    }

    private func initializeSession(on transport: NWConnectionTransport) async throws -> RFBServerInfo {
        try await transport.send(Data([0xc1]))
        let header = try await transport.receiveExactly(24)
        let nameLength = try Int(header.uint32BE(at: 20))
        guard nameLength <= Self.maximumServerNameLength else {
            throw RFBServerInitError.nameTooLong
        }
        let name = try await transport.receiveExactly(nameLength)
        return try RFBServerInfo.parse(header: header, nameData: name)
    }
}
