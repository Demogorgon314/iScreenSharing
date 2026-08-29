import Foundation

protocol RFBAuthenticating: Sendable {
    func connect(
        to endpoint: ConnectionEndpoint,
        credentials: ScreenSharingCredentials,
        sharingType: ScreenSharingType
    ) async throws -> RFBAuthenticatedSession
}

struct RFBAuthenticationService: RFBAuthenticating {
    private static let maximumPublicKeyPacketLength = 64 * 1024
    private static let maximumServerNameLength = 1024 * 1024
    private let routeOpener: any SessionRouteOpening

    init(
        routeOpener: any SessionRouteOpening = SessionRouteOpener()
    ) {
        self.routeOpener = routeOpener
    }

    func connect(
        to endpoint: ConnectionEndpoint,
        credentials: ScreenSharingCredentials,
        sharingType: ScreenSharingType = .highPerformance
    ) async throws -> RFBAuthenticatedSession {
        let route = try await routeOpener.open(endpoint, sharingType: sharingType)
        let transport = route.control
        do {
            let probe = try await performVersionHandshake(on: transport)
            guard probe.securityTypes.contains(.appleRSA) else {
                throw AppleRSA1Error.unsupportedServer
            }

            let masterKey = try await authenticateRSA1(
                credentials: credentials,
                transport: transport
            )
            let serverInfo = try await initializeSession(
                on: transport,
                sharingType: sharingType
            )
            return RFBAuthenticatedSession(
                endpoint: endpoint,
                sharingType: sharingType,
                masterKey: masterKey,
                serverInfo: serverInfo,
                route: route
            )
        } catch {
            route.close()
            throw error
        }
    }

    private func performVersionHandshake(
        on transport: any RFBTransport
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
        transport: any RFBTransport
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

    private func initializeSession(
        on transport: any RFBTransport,
        sharingType: ScreenSharingType
    ) async throws -> RFBServerInfo {
        try await transport.send(
            sharingType == .standard ? StandardRFBMessages.clientInit : Data([0xc1])
        )
        let header = try await transport.receiveExactly(24)
        let nameLength = try Int(header.uint32BE(at: 20))
        guard nameLength <= Self.maximumServerNameLength else {
            throw RFBServerInitError.nameTooLong
        }
        let name = try await transport.receiveExactly(nameLength)
        return try RFBServerInfo.parse(header: header, nameData: name)
    }
}
