import Foundation
import ScreenSharingProtocol

protocol RFBAuthenticating: Sendable {
    func connect(
        to endpoint: ConnectionEndpoint,
        credentials: ScreenSharingCredentials,
        sharingType: ScreenSharingType
    ) async throws -> RFBAuthenticatedSession
}

enum RFBAuthenticationError: LocalizedError, Equatable {
    case unsupportedAppleRSA
    case serverNameTooLong

    var errorDescription: String? {
        switch self {
        case .unsupportedAppleRSA:
            "This Mac doesn’t offer the supported Apple RSA authentication method."
        case .serverNameTooLong:
            "The Mac returned a display name that is too large."
        }
    }
}

struct RFBAuthenticationService: RFBAuthenticating {
    private static let maximumPublicKeyPacketLength = 64 * 1024
    static let maximumServerNameLength = 1024 * 1024
    private let routeOpener: any SessionRouteOpening

    init(
        routeOpener: any SessionRouteOpening = SessionRouteOpener()
    ) {
        self.routeOpener = routeOpener
    }

    static func validateServerNameLength(_ length: Int) throws {
        guard length <= maximumServerNameLength else {
            throw RFBAuthenticationError.serverNameTooLong
        }
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
                throw RFBAuthenticationError.unsupportedAppleRSA
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

        try await Self.receiveRSA1PrivateResponse(on: transport)
        try AppleRSA1.parseSecurityResult(try await transport.receiveExactly(4))
        return masterKey
    }

    static func receiveRSA1PrivateResponse(
        on transport: any RFBTransport
    ) async throws {
        let lengthData = try await transport.receiveExactly(4)
        let length = try Int(lengthData.uint32BE(at: 0))
        guard length <= AppleRSA1.maximumPrivateResponseLength else {
            throw AppleRSA1Error.privateAuthenticationResponseTooLarge
        }
        let body = length == 0 ? Data() : try await transport.receiveExactly(length)
        // Native routes types 0 and 3 to host-key and support-list state outside
        // the RSA-plain exchange, while unknown types fall through to SecurityResult.
        switch try AppleRSA1.privateAuthenticationResponseType(body) {
        case 0:
            throw AppleRSA1Error.serverTrustResponseUnsupported
        case 3:
            throw AppleRSA1Error.authenticationSupportResponseUnsupported
        default:
            return
        }
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
        try Self.validateServerNameLength(nameLength)
        let name = try await transport.receiveExactly(nameLength)
        return try RFBServerInfo.parse(header: header, nameData: name)
    }
}
