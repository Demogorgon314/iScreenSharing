import Foundation

struct AppleMediaNegotiationResult: Equatable, Sendable {
    let keys: AppleMediaKeys
    let canvas: AppleCanvas
    let videoSynchronizationSource: UInt32
    let configuration: Data
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
        var retryCount = 0
        negotiationLoop: while retryCount <= Self.retryLimit {
            let response = try await session.receiveEncrypted()
            switch AppleMediaConfiguration.answerStatus(from: response) {
            case .canvas(let canvas):
                let result = AppleMediaNegotiationResult(
                    keys: keys,
                    canvas: canvas,
                    videoSynchronizationSource: offers.videoSynchronizationSource,
                    configuration: configuration,
                    pendingMessages: pendingMessages
                )
                session.install(mediaNegotiation: result)
                receiver.stopPunching()
                return result
            case .unrelated:
                pendingMessages.append(response)
                continue
            case .degenerate:
                guard retryCount < Self.retryLimit else { break negotiationLoop }
                retryCount += 1
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
