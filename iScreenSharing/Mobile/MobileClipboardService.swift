import Combine
import UIKit
import UniformTypeIdentifiers

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
        let items = pasteboard.items.enumerated().compactMap {
            index, pasteboardItem -> AppleClipboardItem? in
            let itemSet = IndexSet(integer: index)
            let flavors = pasteboardItem.keys.compactMap {
                type -> AppleClipboardFlavor? in
                guard Self.shouldSynchronize(type),
                      let value = pasteboard.data(
                          forPasteboardType: type,
                          inItemSet: itemSet
                      )?.first else { return nil }
                return AppleClipboardFlavor(type: type, aliases: [], value: value)
            }
            return flavors.isEmpty ? nil : AppleClipboardItem(flavors: flavors)
        }
        return items.isEmpty ? nil : AppleClipboardArchive(items: items)
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
        let pasteboardItems = archive.items.compactMap { archiveItem -> [String: Any]? in
            var item = [String: Any]()
            for flavor in archiveItem.flavors {
                guard let identifier = Self.resolvedTypeIdentifier(for: flavor),
                      Self.shouldSynchronize(identifier) else { continue }
                item[identifier] = flavor.value
            }
            return item.isEmpty ? nil : item
        }
        guard !pasteboardItems.isEmpty else { return }
        pasteboard.setItems(pasteboardItems, options: [:])
        ignoredChangeCount = pasteboard.changeCount
        lastReceivedText = archive.preferredText
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

    private static func shouldSynchronize(_ identifier: String) -> Bool {
        !identifier.hasPrefix("dyn.")
            && !pasteboardPeekerTypes.contains(identifier)
            && !excludedTypes.contains(identifier)
    }

    private static func resolvedTypeIdentifier(for flavor: AppleClipboardFlavor) -> String? {
        if !flavor.type.isEmpty { return flavor.type }
        for alias in flavor.aliases {
            switch alias.tagClass {
            case "com.apple.nspboard-type":
                return alias.preferredTag
            case "public.mime-type":
                if let type = UTType(mimeType: alias.preferredTag) { return type.identifier }
            case "public.filename-extension":
                if let type = UTType(filenameExtension: alias.preferredTag) { return type.identifier }
            default:
                let tagClass = UTTagClass(rawValue: alias.tagClass)
                if let type = UTType(
                    tag: alias.preferredTag,
                    tagClass: tagClass,
                    conformingTo: nil
                ) {
                    return type.identifier
                }
            }
        }
        return nil
    }

    private static let pasteboardPeekerTypes: Set<String> = [
        "com.apple.pasteboardpeeker.lowercasetext",
        "com.apple.pasteboardpeeker.uppercasetext",
    ]

    private static let excludedTypes: Set<String> = [
        UTType.fileURL.identifier,
        "com.apple.pasteboard.NSFilePromiseID",
        "com.apple.pasteboard.NSFilePromiseContent",
        "com.apple.pasteboard.promised-file-url",
        "com.apple.pasteboard.promised-file-content-type",
        "com.ilm.openexr-image",
    ]
}
