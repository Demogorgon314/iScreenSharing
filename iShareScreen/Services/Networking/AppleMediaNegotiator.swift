import Foundation

struct AppleMediaNegotiationResult: Equatable, Sendable {
    let keys: AppleMediaKeys
    let canvas: AppleCanvas
    let videoSynchronizationSource: UInt32
    let pendingMessages: [Data]
}

protocol AppleMediaNegotiating: Sendable {
    func negotiate(_ session: RFBAuthenticatedSession) async throws -> AppleMediaNegotiationResult
}

struct AppleMediaNegotiator: AppleMediaNegotiating {
    private static let retryLimit = 16

    func negotiate(_ session: RFBAuthenticatedSession) async throws -> AppleMediaNegotiationResult {
        let receiver = try AppleMediaReceiver(endpoint: session.endpoint)
        session.install(mediaReceiver: receiver)
        do {
            return try await negotiate(session, receiver: receiver)
        } catch {
            receiver.close()
            throw error
        }
    }

    private func negotiate(
        _ session: RFBAuthenticatedSession,
        receiver: AppleMediaReceiver
    ) async throws -> AppleMediaNegotiationResult {
        let offers = try AppleMediaOffer.create()
        let keys = try AppleMediaKeys.random()
        let configuration = try AppleMediaConfiguration.message(
            audioOffer: offers.audio,
            videoOffer: offers.video,
            keys: keys
        )

        try await session.sendEncrypted(try AppleRFBMessages.setEncodings())
        try await session.sendEncrypted(configuration)
        try await session.sendEncrypted(AppleRFBMessages.framebufferUpdateRequest())

        var pendingMessages = [Data]()
        for attempt in 0...Self.retryLimit {
            let response = try await session.receiveEncrypted()
            if let canvas = AppleMediaConfiguration.canvas(from: response) {
                let result = AppleMediaNegotiationResult(
                    keys: keys,
                    canvas: canvas,
                    videoSynchronizationSource: offers.videoSynchronizationSource,
                    pendingMessages: pendingMessages
                )
                session.install(mediaNegotiation: result)
                receiver.stopPunching()
                return result
            }
            pendingMessages.append(response)
            if attempt < Self.retryLimit {
                try await Task.sleep(for: .milliseconds(200))
                try await session.sendEncrypted(configuration)
            }
        }
        throw AppleMediaNegotiationError.missingCanvas
    }
}

enum AppleMediaNegotiationError: LocalizedError, Equatable {
    case missingCanvas

    var errorDescription: String? {
        "The remote Mac did not provide a usable screen canvas."
    }
}
