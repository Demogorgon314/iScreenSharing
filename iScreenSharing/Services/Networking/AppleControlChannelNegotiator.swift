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
        try await session.send(
            AppleRFBMessages.viewerInfo() + AppleRFBMessages.setEncryption
        )
        try await Task.sleep(for: .milliseconds(100))
        try await session.send(try AppleRFBMessages.setEncodings())

        let rekey = try await AppleRekeyReader().read(from: session)
        let keys = try rekey.unwrap(using: session.masterKey)
        let recordLayer = AppleEncryptedRecordLayer(keys: keys)
        session.install(recordLayer: recordLayer)

        try await session.send(AppleRFBMessages.postEncryptionToggle)
        try await Task.sleep(for: .milliseconds(200))
        try await session.sendEncrypted(
            AppleDisplayConfiguration.message(
                displaySizes: displaySizes
            )
        )
        return recordLayer
    }
}
