import Carbon
import Combine
import Foundation

@MainActor
final class AppleKeyboardInputSourceService: ObservableObject {
    @Published private(set) var isSharingEnabled: Bool
    @Published private(set) var isSupported = false
    @Published private(set) var remoteIdentifier: String?
    @Published private(set) var serverUsesSecureInput = false

    private let currentIdentifier: () -> String?
    private let send: @Sendable (Data) async throws -> Void
    private let updateUsesSameInputSource: @Sendable (Bool) async -> Void
    private let didChangeSharingEnabled: (Bool) -> Void
    private var notificationObserver: NSObjectProtocol?
    private var stateUpdateTask: Task<Void, Never>?
    private var isControlling = true
    private var hasStarted = false
    private var isClosed = false

    init(
        isSharingEnabled: Bool = false,
        currentIdentifier: @escaping () -> String? = AppleKeyboardInputSource.currentIdentifier,
        send: @escaping @Sendable (Data) async throws -> Void,
        updateUsesSameInputSource: @escaping @Sendable (Bool) async -> Void = { _ in },
        didChangeSharingEnabled: @escaping (Bool) -> Void = { _ in }
    ) {
        self.isSharingEnabled = isSharingEnabled
        self.currentIdentifier = currentIdentifier
        self.send = send
        self.updateUsesSameInputSource = updateUsesSameInputSource
        self.didChangeSharingEnabled = didChangeSharingEnabled
    }

    func start() {
        guard !hasStarted, !isClosed else { return }
        hasStarted = true
        let name = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        notificationObserver = DistributedNotificationCenter.default().addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.inputSourceDidChange() }
        }
        scheduleStateUpdate(sendMessage: isSharingEnabled && isSupported && isControlling)
    }

    func setSharingEnabled(_ enabled: Bool) {
        guard !isClosed, isControlling,
              (!enabled || isSupported), enabled != isSharingEnabled else { return }
        isSharingEnabled = enabled
        didChangeSharingEnabled(enabled)
        scheduleStateUpdate(sendMessage: true)
    }

    func setControlling(_ controlling: Bool) {
        guard !isClosed, controlling != isControlling else { return }
        isControlling = controlling
        scheduleStateUpdate(sendMessage: controlling && isSharingEnabled && isSupported)
    }

    func receive(_ state: AppleKeyboardInputSourceState) {
        isSupported = true
        remoteIdentifier = state.identifier
        serverUsesSecureInput = state.isSecureInput
        scheduleStateUpdate(
            sendMessage: hasStarted && isControlling && isSharingEnabled
        )
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        stateUpdateTask?.cancel()
        stateUpdateTask = nil
        if let notificationObserver {
            DistributedNotificationCenter.default().removeObserver(notificationObserver)
        }
        notificationObserver = nil
    }

    private func inputSourceDidChange() {
        scheduleStateUpdate(sendMessage: isControlling && isSharingEnabled && isSupported)
    }

    private func scheduleStateUpdate(sendMessage: Bool) {
        stateUpdateTask?.cancel()
        let identifier = currentIdentifier()
        let usesSameInputSource = isSharingEnabled
            || (remoteIdentifier != nil && remoteIdentifier == identifier)
        let message: Data?
        if sendMessage {
            message = try? AppleKeyboardInputSourceMessage.share(
                identifier: isSharingEnabled ? identifier : nil
            )
        } else {
            message = nil
        }
        stateUpdateTask = Task { [updateUsesSameInputSource, send] in
            guard !Task.isCancelled else { return }
            await updateUsesSameInputSource(usesSameInputSource)
            guard !Task.isCancelled, let message else { return }
            try? await send(message)
        }
    }
}

private enum AppleKeyboardInputSource {
    static func currentIdentifier() -> String? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}
