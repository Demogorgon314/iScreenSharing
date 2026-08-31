import enum ScreenSharingProtocol.AppleDisplayConfiguration
import class ScreenSharingProtocol.AppleEncryptedRecordLayer
import struct ScreenSharingProtocol.AppleDynamicResolutionSize
import enum ScreenSharingProtocol.AppleRFBMessages
import enum ScreenSharingProtocol.AppleRecordKeyError
import struct ScreenSharingProtocol.AppleRecordKeys
import struct ScreenSharingProtocol.RFBServerInfo
import XCTest
@testable import iScreenSharing

final class AppleControlChannelNegotiatorTests: XCTestCase {
    func testValidRekeyAdvancesToEncryptedConfigurationInNativeOrder() async throws {
        let masterKey = Data(repeating: 0x11, count: 16)
        let contentKey = Data((0..<16).map(UInt8.init))
        let initializationVector = Data((16..<32).map(UInt8.init))
        let transport = ControlNegotiationTransport(
            rekeyFrame: try rekeyFrame(
                masterKey: masterKey,
                contentKey: contentKey,
                initializationVector: initializationVector
            )
        )
        let session = try makeSession(
            masterKey: masterKey,
            transport: transport
        )
        let displaySizes = [
            AppleDynamicResolutionSize(width: 1_440, height: 900),
        ]

        _ = try await AppleControlChannelNegotiator().enableEncryption(
            for: session,
            displaySizes: displaySizes
        )

        let expectedLayer = AppleEncryptedRecordLayer(keys: try AppleRecordKeys(
            key: contentKey,
            initializationVector: initializationVector
        ))
        let encryptedDisplayConfiguration = try expectedLayer.encrypt(
            AppleDisplayConfiguration.message(displaySizes: displaySizes)
        )
        let encryptedEncodings = try expectedLayer.encrypt(
            AppleRFBMessages.setEncodings()
        )
        XCTAssertEqual(transport.sentMessages, [
            AppleRFBMessages.viewerInfo(),
            AppleRFBMessages.setEncryption,
            AppleRFBMessages.postEncryptionToggle,
            encryptedDisplayConfiguration,
            encryptedEncodings,
        ])
        XCTAssertNotNil(session.recordLayer)
        session.close()
    }

    func testAcknowledgesValidRekeyBeforeLocalKeyUnwrapFailure() async throws {
        let wrappingKey = Data(repeating: 0x11, count: 16)
        let transport = ControlNegotiationTransport(
            rekeyFrame: try rekeyFrame(
                masterKey: wrappingKey,
                contentKey: Data(repeating: 0x22, count: 16),
                initializationVector: Data(repeating: 0x33, count: 16)
            )
        )
        let session = try makeSession(masterKey: Data(), transport: transport)

        do {
            _ = try await AppleControlChannelNegotiator().enableEncryption(
                for: session,
                displaySizes: [AppleDynamicResolutionSize(width: 1_440, height: 900)]
            )
            XCTFail("Expected the invalid wrapping key to fail")
        } catch let error as AppleRecordKeyError {
            XCTAssertEqual(error, .decryptionFailed)
            XCTAssertEqual(transport.sentMessages, [
                AppleRFBMessages.viewerInfo(),
                AppleRFBMessages.setEncryption,
                AppleRFBMessages.postEncryptionToggle,
            ])
            XCTAssertNil(session.recordLayer)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        session.close()
    }

    private func makeSession(
        masterKey: Data,
        transport: ControlNegotiationTransport
    ) throws -> RFBAuthenticatedSession {
        let endpoint = try ConnectionEndpoint("example.local")
        return RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: try ResolvedRemoteAddress(
                numericHost: "127.0.0.1",
                port: endpoint.port
            ),
            masterKey: masterKey,
            serverInfo: RFBServerInfo(
                width: 1_920,
                height: 1_080,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Test Mac"
            ),
            transport: transport
        )
    }

    private func rekeyFrame(
        masterKey: Data,
        contentKey: Data,
        initializationVector: Data
    ) throws -> Data {
        var frame = Data([
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x04, 0x4f,
            0x00, 0x00, 0x00, 0x01,
        ])
        frame.append(try Cryptography.encryptAESECB(contentKey, key: masterKey))
        frame.append(try Cryptography.encryptAESECB(
            initializationVector,
            key: masterKey
        ))
        return frame
    }
}

private final class ControlNegotiationTransport: RFBTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var receiveBuffer: Data
    private var messages = [Data]()

    init(rekeyFrame: Data) {
        receiveBuffer = rekeyFrame
    }

    var sentMessages: [Data] {
        lock.withControlNegotiationLock { messages }
    }

    func start(timeout: Duration) async throws {}

    func send(_ data: Data) async throws {
        lock.withControlNegotiationLock { messages.append(data) }
    }

    func receiveExactly(_ length: Int) async throws -> Data {
        try lock.withControlNegotiationLock {
            guard receiveBuffer.count >= length else {
                throw RFBNetworkError.connectionClosed
            }
            let data = Data(receiveBuffer.prefix(length))
            receiveBuffer.removeFirst(length)
            return data
        }
    }

    func cancel() {}
}

private extension NSLock {
    func withControlNegotiationLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
