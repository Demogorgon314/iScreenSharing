import Foundation

struct AppleMediaReceiverFactory: Sendable {
    private let tailscaleNodeProvider: any TailscaleNodeProviding

    init(tailscaleNodeProvider: any TailscaleNodeProviding = EmbeddedTailscaleRuntime.shared) {
        self.tailscaleNodeProvider = tailscaleNodeProvider
    }

    func makeReceiver(
        for session: RFBAuthenticatedSession,
        displayCount: Int
    ) async throws -> any AppleMediaReceiving {
        switch session.endpoint.route {
        case .direct:
            return try AppleMediaReceiver(
                remoteAddress: session.remoteAddress,
                displayCount: displayCount
            )
        case .tailscale:
            return try await TailscaleMediaReceiver.create(
                remoteAddress: session.remoteAddress,
                displayCount: displayCount,
                nodeProvider: tailscaleNodeProvider
            )
        }
    }
}
