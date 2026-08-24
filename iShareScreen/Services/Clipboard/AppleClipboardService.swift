import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
protocol AppleClipboardReceiving: AnyObject {
    var allowsRemoteSynchronization: Bool { get }
    func localArchive() -> AppleClipboardArchive?
    func archiveForRemoteRequest() -> AppleClipboardArchive?
    func receive(_ archive: AppleClipboardArchive)
    func synchronizationLease() -> UInt64?
    func isSynchronizationLeaseValid(_ lease: UInt64) -> Bool
    func receiveIfEligible(_ archive: AppleClipboardArchive, lease: UInt64) -> Bool
}

@MainActor
final class AppleClipboardService: ObservableObject, AppleClipboardReceiving {
    @Published private(set) var lastReceivedText: String?

    private let pasteboard: NSPasteboard
    private let advertise: @Sendable (AppleClipboardArchive) async throws -> Void
    private let isApplicationActive: () -> Bool
    private var pasteboardChangeCount: Int
    private var keySessionWindows = Set<UUID>()
    private var lastAdvertisedArchive: AppleClipboardArchive?
    private var advertisementTask: Task<Void, Never>?
    private var isControlling = true
    private var isClosed = false
    private var eligibilityGeneration: UInt64 = 0

    var allowsRemoteSynchronization: Bool {
        !isClosed && isControlling && !keySessionWindows.isEmpty && isApplicationActive()
    }

    init(
        pasteboard: NSPasteboard = .general,
        advertise: @escaping @Sendable (AppleClipboardArchive) async throws -> Void = { _ in },
        isApplicationActive: (() -> Bool)? = nil
    ) {
        self.pasteboard = pasteboard
        self.advertise = advertise
        self.isApplicationActive = isApplicationActive ?? { NSApplication.shared.isActive }
        pasteboardChangeCount = pasteboard.changeCount
    }

    func start() {
        guard !isClosed else { return }
        pasteboardChangeCount = pasteboard.changeCount
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
        let wasEligible = allowsRemoteSynchronization
        isControlling = controlling
        eligibilityDidChange(from: wasEligible)
    }

    func localArchive() -> AppleClipboardArchive? {
        let items = (pasteboard.pasteboardItems ?? []).compactMap { pasteboardItem -> AppleClipboardItem? in
            let flavors = pasteboardItem.types.compactMap { type -> AppleClipboardFlavor? in
                guard Self.shouldSynchronize(type),
                      let value = pasteboardItem.data(forType: type) else { return nil }
                return AppleClipboardFlavor(type: type.rawValue, aliases: [], value: value)
            }
            return flavors.isEmpty ? nil : AppleClipboardItem(flavors: flavors)
        }
        return items.isEmpty ? nil : AppleClipboardArchive(items: items)
    }

    func localText() -> String? {
        pasteboard.string(forType: .string)
    }

    func archiveForRemoteRequest() -> AppleClipboardArchive? {
        lastAdvertisedArchive ?? localArchive()
    }

    func receive(_ archive: AppleClipboardArchive) {
        let pasteboardItems = archive.items.compactMap { archiveItem -> NSPasteboardItem? in
            let item = NSPasteboardItem()
            var wroteFlavor = false
            for flavor in archiveItem.flavors {
                guard let identifier = Self.resolvedTypeIdentifier(for: flavor) else { continue }
                let type = NSPasteboard.PasteboardType(identifier)
                guard Self.shouldSynchronize(type) else { continue }
                wroteFlavor = item.setData(flavor.value, forType: type) || wroteFlavor
            }
            return wroteFlavor ? item : nil
        }
        guard !pasteboardItems.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(pasteboardItems)
        pasteboardChangeCount = pasteboard.changeCount
        lastAdvertisedArchive = nil
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
        advertisementTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await advertise(archive)
                guard !Task.isCancelled else { return }
                advertisementDidFinish(
                    archive: archive,
                    changeCount: advertisedChangeCount,
                    succeeded: true
                )
            } catch {
                advertisementDidFinish(
                    archive: archive,
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
        }
    }

    private func advertisementDidFinish(
        archive: AppleClipboardArchive,
        changeCount: Int,
        succeeded: Bool
    ) {
        advertisementTask = nil
        guard succeeded, !isClosed else { return }
        pasteboardChangeCount = changeCount
        lastAdvertisedArchive = archive
        if pasteboard.changeCount != changeCount {
            synchronizeIfChanged()
        }
    }

    private static func shouldSynchronize(_ type: NSPasteboard.PasteboardType) -> Bool {
        let identifier = type.rawValue
        return !identifier.hasPrefix("dyn.")
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
                if let type = UTType(tag: alias.preferredTag, tagClass: tagClass, conformingTo: nil) {
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
        "public.file-url",
        "com.apple.pasteboard.NSFilePromiseID",
        "com.apple.pasteboard.NSFilePromiseContent",
        "com.apple.pasteboard.promised-file-url",
        "com.apple.pasteboard.promised-file-content-type",
        "com.ilm.openexr-image"
    ]
}
