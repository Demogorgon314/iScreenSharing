import Foundation
import OSLog
import enum ScreenSharingProtocol.AppleRFBMessages

@MainActor
final class SessionWindowFrameUpdateController {
    typealias Send = @Sendable (Data) async throws -> Void

    private static let logger = Logger(
        subsystem: "com.wangkai.iShareScreen",
        category: "WindowFrameUpdates"
    )

    private let send: Send
    private var isPaused = false
    private var pendingSend = Task<Void, Never> { }

    init(send: @escaping Send) {
        self.send = send
    }

    func setMiniaturized(_ miniaturized: Bool, endpointWindowCount: Int) {
        if miniaturized {
            guard endpointWindowCount == 1, !isPaused else { return }
            isPaused = true
            enqueue(intervalMilliseconds: .max)
        } else {
            guard isPaused else { return }
            isPaused = false
            enqueue(intervalMilliseconds: 0)
        }
    }

    func waitForPendingSend() async {
        await pendingSend.value
    }

    private func enqueue(intervalMilliseconds: UInt32) {
        let predecessor = pendingSend
        let message = AppleRFBMessages.autoFramebufferUpdate(
            intervalMilliseconds: intervalMilliseconds
        )
        pendingSend = Task { [send] in
            await predecessor.value
            do {
                try await send(message)
            } catch {
                Self.logger.error(
                    "Could not update minimized-window frame delivery: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
