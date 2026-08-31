import Combine
import Foundation
import enum ScreenSharingProtocol.AppleRFBMessages

@MainActor
final class AppleSessionControlState: ObservableObject {
    @Published private(set) var isObserving = false
    @Published private(set) var isChangingMode = false
    @Published private(set) var errorMessage: String?

    private weak var session: RFBAuthenticatedSession?

    init(session: RFBAuthenticatedSession) {
        self.session = session
    }

    func toggleMode() {
        guard !isChangingMode, let session else { return }
        let newValue = !isObserving
        isChangingMode = true
        Task { [weak self, weak session] in
            guard let self, let session else { return }
            do {
                let message = AppleRFBMessages.controlMode(observing: newValue)
                switch session.sharingType {
                case .standard:
                    try await session.sendStandard(message)
                case .highPerformance:
                    try await session.sendEncrypted(
                        message
                    )
                }
                await session.inputController?.setControlling(!newValue)
                await session.fileTransferService?.setControlling(!newValue)
                guard !Task.isCancelled else { return }
                isObserving = newValue
                session.clipboardService?.setControlling(!newValue)
                session.keyboardInputSourceService?.setControlling(!newValue)
                isChangingMode = false
            } catch {
                errorMessage = error.localizedDescription
                isChangingMode = false
            }
        }
    }

    func clearError() {
        errorMessage = nil
    }
}
