import AppKit
import Combine
import Foundation
import struct ScreenSharingProtocol.AppleClipboardArchive
import struct ScreenSharingProtocol.AppleClipboardFlavor
import struct ScreenSharingProtocol.AppleClipboardItem

@MainActor
protocol AppleClipboardReceiving: AnyObject {
    var allowsRemoteSynchronization: Bool { get }
    func localArchive() -> AppleClipboardArchive?
    func archiveForRemoteRequest() -> AppleClipboardArchive?
    func remoteRequestDidFinish()
    func remotePasteboardDidChange()
    func receive(_ archive: AppleClipboardArchive)
    func synchronizationLease() -> UInt64?
    func isSynchronizationLeaseValid(_ lease: UInt64) -> Bool
    func receiveIfEligible(_ archive: AppleClipboardArchive, lease: UInt64) -> Bool
}

@MainActor
final class AppleClipboardService: ObservableObject, AppleClipboardReceiving {
    @Published private(set) var lastReceivedText: String?
    @Published private(set) var isSharingEnabled: Bool

    private let pasteboard: NSPasteboard
    private let typeResolver: AppleClipboardTypeResolver
    private let advertise: @Sendable (AppleClipboardArchive) async throws -> Void
    private let updateRemoteSharingEnabled: @Sendable (Bool) async -> Void
    private let didChangeSharingEnabled: @MainActor (Bool) -> Void
    private let isApplicationActive: () -> Bool
    private let supportsSharedClipboard: Bool
    private var pasteboardChangeCount: Int
    private var keySessionWindows = Set<UUID>()
    private var hasUnfulfilledPromises = false
    private var advertisementTask: Task<Void, Never>?
    private var sharingStateTask: Task<Void, Never>?
    private var isControlling = true
    private var hasStarted = false
    private var isClosed = false
    private var eligibilityGeneration: UInt64 = 0

    var allowsRemoteSynchronization: Bool {
        isSharingEnabled && !isClosed && isControlling
            && !keySessionWindows.isEmpty && isApplicationActive()
    }

    init(
        pasteboard: NSPasteboard = .general,
        isSharingEnabled: Bool = true,
        supportsSharedClipboard: Bool = true,
        advertise: @escaping @Sendable (AppleClipboardArchive) async throws -> Void = { _ in },
        updateRemoteSharingEnabled: @escaping @Sendable (Bool) async -> Void = { _ in },
        didChangeSharingEnabled: @escaping @MainActor (Bool) -> Void = { _ in },
        isApplicationActive: (() -> Bool)? = nil,
        typeResolver: AppleClipboardTypeResolver = .system
    ) {
        self.pasteboard = pasteboard
        self.typeResolver = typeResolver
        self.supportsSharedClipboard = supportsSharedClipboard
        self.isSharingEnabled = supportsSharedClipboard && isSharingEnabled
        self.advertise = advertise
        self.updateRemoteSharingEnabled = updateRemoteSharingEnabled
        self.didChangeSharingEnabled = didChangeSharingEnabled
        self.isApplicationActive = isApplicationActive ?? { NSApplication.shared.isActive }
        pasteboardChangeCount = pasteboard.changeCount
    }

    func start() {
        guard !hasStarted, !isClosed else { return }
        hasStarted = true
        pasteboardChangeCount = pasteboard.changeCount
        scheduleRemoteSharingStateUpdate()
    }

    func setSessionWindow(_ identifier: UUID, isKey: Bool) {
        guard !isClosed else { return }
        let wasEligible = allowsRemoteSynchronization
        if isKey {
            keySessionWindows.insert(identifier)
        } else {
            keySessionWindows.remove(identifier)
        }
        eligibilityDidChange(from: wasEligible)
    }

    func setControlling(_ controlling: Bool) {
        guard !isClosed, controlling != isControlling else { return }
        let wasEligible = allowsRemoteSynchronization
        isControlling = controlling
        eligibilityDidChange(from: wasEligible)
        scheduleRemoteSharingStateUpdate()
    }

    func setSharingEnabled(_ enabled: Bool) {
        guard !isClosed, isControlling, supportsSharedClipboard,
              enabled != isSharingEnabled else { return }
        let wasEligible = allowsRemoteSynchronization
        pasteboardChangeCount = pasteboard.changeCount
        isSharingEnabled = enabled
        if !enabled { hasUnfulfilledPromises = false }
        didChangeSharingEnabled(enabled)
        eligibilityDidChange(from: wasEligible)
        scheduleRemoteSharingStateUpdate()
    }

    func localArchive() -> AppleClipboardArchive? {
        let items = (pasteboard.pasteboardItems ?? []).compactMap { pasteboardItem -> AppleClipboardItem? in
            let flavors = pasteboardItem.types.compactMap { type -> AppleClipboardFlavor? in
                guard Self.shouldSynchronize(type),
                      let value = pasteboardItem.data(forType: type) else { return nil }
                return AppleClipboardFlavor(
                    type: type.rawValue,
                    aliases: typeResolver.aliases(for: type.rawValue),
                    value: value
                )
            }
            return flavors.isEmpty ? nil : AppleClipboardItem(flavors: flavors)
        }
        return items.isEmpty ? nil : AppleClipboardArchive(items: items)
    }

    func localText() -> String? {
        pasteboard.string(forType: .string)
    }

    func archiveForRemoteRequest() -> AppleClipboardArchive? {
        let allowed = allowsRemoteSynchronization && hasUnfulfilledPromises
        return allowed ? localArchive() : nil
    }

    func remoteRequestDidFinish() {
        hasUnfulfilledPromises = false
    }

    func remotePasteboardDidChange() {
        hasUnfulfilledPromises = false
    }

    func receive(_ archive: AppleClipboardArchive) {
        let pasteboardItems = archive.items.compactMap { archiveItem -> NSPasteboardItem? in
            let item = NSPasteboardItem()
            var wroteFlavor = false
            for flavor in archiveItem.flavors {
                for identifier in typeResolver.identifiers(for: flavor) {
                    let type = NSPasteboard.PasteboardType(identifier)
                    guard Self.shouldSynchronize(type) else { continue }
                    wroteFlavor = item.setData(flavor.value, forType: type) || wroteFlavor
                }
            }
            return wroteFlavor ? item : nil
        }
        guard !pasteboardItems.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(pasteboardItems)
        pasteboardChangeCount = pasteboard.changeCount
        hasUnfulfilledPromises = false
        lastReceivedText = archive.preferredText
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
        let wasEligible = allowsRemoteSynchronization
        isClosed = true
        advertisementTask?.cancel()
        advertisementTask = nil
        sharingStateTask?.cancel()
        sharingStateTask = nil
        hasUnfulfilledPromises = false
        keySessionWindows.removeAll()
        eligibilityDidChange(from: wasEligible)
    }

    private func synchronizeIfChanged() {
        guard allowsRemoteSynchronization,
              advertisementTask == nil,
              pasteboard.changeCount != pasteboardChangeCount else {
            return
        }
        let advertisedChangeCount = pasteboard.changeCount
        guard let archive = localArchive() else { return }
        hasUnfulfilledPromises = true
        advertisementTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await advertise(archive)
                guard !Task.isCancelled else { return }
                advertisementDidFinish(
                    changeCount: advertisedChangeCount,
                    succeeded: true
                )
            } catch {
                advertisementDidFinish(
                    changeCount: advertisedChangeCount,
                    succeeded: false
                )
            }
        }
    }

    private func eligibilityDidChange(from wasEligible: Bool) {
        let isEligible = allowsRemoteSynchronization
        guard wasEligible != isEligible else { return }
        eligibilityGeneration &+= 1
        if isEligible {
            synchronizeIfChanged()
        } else {
            advertisementTask?.cancel()
            advertisementTask = nil
            hasUnfulfilledPromises = false
        }
    }

    private func advertisementDidFinish(
        changeCount: Int,
        succeeded: Bool
    ) {
        advertisementTask = nil
        guard succeeded, !isClosed else {
            hasUnfulfilledPromises = false
            return
        }
        pasteboardChangeCount = changeCount
        // Native samples the pasteboard when a session window becomes key. A
        // change during this send remains detectable at the next eligibility
        // transition instead of creating a polling-like recursive send loop.
    }

    private func scheduleRemoteSharingStateUpdate() {
        guard hasStarted, supportsSharedClipboard else { return }
        sharingStateTask?.cancel()
        let enabled = isControlling && isSharingEnabled
        sharingStateTask = Task { [updateRemoteSharingEnabled] in
            guard !Task.isCancelled else { return }
            await updateRemoteSharingEnabled(enabled)
        }
    }

    private static func shouldSynchronize(_ type: NSPasteboard.PasteboardType) -> Bool {
        let identifier = type.rawValue
        return !identifier.hasPrefix("dyn.")
            && !pasteboardPeekerTypes.contains(identifier)
            && !excludedTypes.contains(identifier)
    }

    private static let pasteboardPeekerTypes: Set<String> = [
        "com.apple.pasteboardpeeker.lowercasetext",
        "com.apple.pasteboardpeeker.uppercasetext",
    ]

    private static let excludedTypes: Set<String> = [
        "public.file-url",
        "com.apple.pasteboard.NSFilePromiseID",
        "com.apple.pasteboard.NSFilePromiseContent",
        "com.apple.pasteboard.promised-file-url",
        "com.apple.pasteboard.promised-file-content-type",
        "com.ilm.openexr-image"
    ]
}
