import Combine
import UIKit

@MainActor
final class MobileClipboardService: ObservableObject, AppleClipboardReceiving {
    @Published private(set) var lastReceivedText: String?

    private let pasteboard: UIPasteboard
    private let advertise: @Sendable (AppleClipboardArchive) async throws -> Void
    private let updateRemoteSharingEnabled: @Sendable (Bool) async -> Void
    private var observer: NSObjectProtocol?
    private var advertisementTask: Task<Void, Never>?
    private var isActive = false
    private var isControlling = true
    private var isClosed = false
    private var hasUnfulfilledPromises = false
    private var ignoredChangeCount: Int?
    private var eligibilityGeneration: UInt64 = 0

    var allowsRemoteSynchronization: Bool {
        isActive && isControlling && !isClosed
    }

    init(
        pasteboard: UIPasteboard = .general,
        advertise: @escaping @Sendable (AppleClipboardArchive) async throws -> Void,
        updateRemoteSharingEnabled: @escaping @Sendable (Bool) async -> Void
    ) {
        self.pasteboard = pasteboard
        self.advertise = advertise
        self.updateRemoteSharingEnabled = updateRemoteSharingEnabled
    }

    func start() {
        guard observer == nil, !isClosed else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIPasteboard.changedNotification,
            object: pasteboard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pasteboardDidChange() }
        }
        updateRemoteState()
    }

    func setActive(_ active: Bool) {
        guard !isClosed, active != isActive else { return }
        let wasEligible = allowsRemoteSynchronization
        isActive = active
        eligibilityDidChange(from: wasEligible)
        updateRemoteState()
    }

    func setControlling(_ controlling: Bool) {
        guard !isClosed, controlling != isControlling else { return }
        let wasEligible = allowsRemoteSynchronization
        isControlling = controlling
        eligibilityDidChange(from: wasEligible)
        updateRemoteState()
    }

    func localArchive() -> AppleClipboardArchive? {
        pasteboard.string.map(AppleClipboardArchive.text)
    }

    func archiveForRemoteRequest() -> AppleClipboardArchive? {
        allowsRemoteSynchronization && hasUnfulfilledPromises ? localArchive() : nil
    }

    func remoteRequestDidFinish() {
        hasUnfulfilledPromises = false
    }

    func remotePasteboardDidChange() {
        hasUnfulfilledPromises = false
    }

    func receive(_ archive: AppleClipboardArchive) {
        guard let text = archive.preferredText else { return }
        pasteboard.string = text
        ignoredChangeCount = pasteboard.changeCount
        lastReceivedText = text
        hasUnfulfilledPromises = false
    }

    func synchronizationLease() -> UInt64? {
        allowsRemoteSynchronization ? eligibilityGeneration : nil
    }

    func isSynchronizationLeaseValid(_ lease: UInt64) -> Bool {
        allowsRemoteSynchronization && lease == eligibilityGeneration
    }

    func receiveIfEligible(_ archive: AppleClipboardArchive, lease: UInt64) -> Bool {
        guard isSynchronizationLeaseValid(lease) else { return false }
        receive(archive)
        return true
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        advertisementTask?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        Task { [updateRemoteSharingEnabled] in
            await updateRemoteSharingEnabled(false)
        }
    }

    private func eligibilityDidChange(from wasEligible: Bool) {
        guard wasEligible != allowsRemoteSynchronization else { return }
        eligibilityGeneration &+= 1
        if allowsRemoteSynchronization {
            advertiseLocalClipboard()
        } else {
            advertisementTask?.cancel()
            advertisementTask = nil
            hasUnfulfilledPromises = false
        }
    }

    private func advertiseLocalClipboard() {
        guard allowsRemoteSynchronization,
              advertisementTask == nil,
              let archive = localArchive() else { return }
        hasUnfulfilledPromises = true
        advertisementTask = Task { [weak self, advertise] in
            defer { self?.advertisementTask = nil }
            do {
                try await advertise(archive)
            } catch {
                self?.hasUnfulfilledPromises = false
            }
        }
    }

    private func pasteboardDidChange() {
        if ignoredChangeCount == pasteboard.changeCount {
            ignoredChangeCount = nil
            return
        }
        advertiseLocalClipboard()
    }

    private func updateRemoteState() {
        let enabled = allowsRemoteSynchronization
        Task { [updateRemoteSharingEnabled] in
            await updateRemoteSharingEnabled(enabled)
        }
    }
}
