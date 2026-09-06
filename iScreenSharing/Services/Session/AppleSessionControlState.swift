import Combine
import Foundation

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
        guard !isChangingMode, let session, let input = session.inputController else { return }
        let newValue = !isObserving
        isChangingMode = true
        input.enqueueInput { [weak self, weak session] in
            guard let self, let session else { return }
            do {
                try await input.setControlling(!newValue)
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
