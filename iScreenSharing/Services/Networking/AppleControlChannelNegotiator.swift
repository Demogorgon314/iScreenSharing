import Foundation
import enum ScreenSharingProtocol.AppleDisplayConfiguration
import enum ScreenSharingProtocol.AppleRFBMessages
import class ScreenSharingProtocol.AppleEncryptedRecordLayer
import struct ScreenSharingProtocol.AppleDynamicResolutionSize

protocol AppleControlChannelNegotiating: Sendable {
    func enableEncryption(
        for session: RFBAuthenticatedSession,
        displaySizes: [AppleDynamicResolutionSize]
    ) async throws -> AppleEncryptedRecordLayer
}

struct AppleControlChannelNegotiator: AppleControlChannelNegotiating {
    func enableEncryption(
        for session: RFBAuthenticatedSession,
        displaySizes: [AppleDynamicResolutionSize]
    ) async throws -> AppleEncryptedRecordLayer {
        try await session.send(AppleRFBMessages.viewerInfo())
        try await session.send(AppleRFBMessages.setEncryption)

        let rekey = try await AppleRekeyReader().read(from: session)
        try await session.send(AppleRFBMessages.postEncryptionToggle)
        let keys = try rekey.unwrap(using: session.masterKey)
        let recordLayer = AppleEncryptedRecordLayer(keys: keys)
        session.install(recordLayer: recordLayer)

        try await session.sendEncrypted(
            AppleDisplayConfiguration.message(
                displaySizes: displaySizes
            )
        )
        try await session.sendEncrypted(try AppleRFBMessages.setEncodings())
        return recordLayer
    }
}
