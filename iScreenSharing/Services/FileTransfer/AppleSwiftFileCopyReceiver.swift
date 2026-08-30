import Darwin
import Foundation
import struct ScreenSharingProtocol.AppleFileCopyExtendedAttribute
import enum ScreenSharingProtocol.AppleFileCopyItemType
import struct ScreenSharingProtocol.AppleFileCopyItemMetadata
import enum ScreenSharingProtocol.AppleFileCopyReceiverPayload
import struct ScreenSharingProtocol.AppleFileCopySummary
import struct ScreenSharingProtocol.AppleFileCopyUTCDateTime
import class ScreenSharingProtocol.ZlibSyncFlushDecompressor

enum AppleSwiftFileCopyReceiverError: LocalizedError, Equatable {
    case invalidSequence
    case invalidItem
    case writeFailed
    case remoteFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidSequence, .invalidItem:
            "The remote Mac sent invalid file transfer data."
        case .writeFailed:
            "The received file could not be written."
        case .remoteFailed:
            "The remote Mac could not send the file."
        }
    }
}

final class AppleSwiftFileCopyReceiver {
    struct Update: Equatable {
        let progress: Double?
        let completedURL: URL?
    }

    private enum Fork {
        case data
        case resource
    }

    private struct CurrentItem {
        let url: URL
        let metadata: AppleFileCopyItemMetadata
        var fork: Fork
        var remainingBytes: UInt64
        var handle: FileHandle
    }

    private static let macEpochOffset: Int64 = 2_082_844_800
    // Native marks only the root catalog entry with 1984-01-24 08:00 UTC
    // while a transfer is incomplete. Wire dates are seconds since 1904.
    private static let inProgressDate = AppleFileCopyUTCDateTime(
        seconds: 2_526_624_000,
        fraction: 0
    )

    private let destinationDirectory: URL
    private let requestedName: String
    private var summary: AppleFileCopySummary?
    private var parentDirectories = [UInt16: URL]()
    private var currentItem: CurrentItem?
    private var decompressor: ZlibSyncFlushDecompressor?
    private var rootURL: URL?
    private var rootMetadata: AppleFileCopyItemMetadata?
    private var transferredBytes: UInt64 = 0
    private var didFinish = false

    init(destinationDirectory: URL, requestedName: String) throws {
        guard destinationDirectory.isFileURL,
              Self.isValidComponent(requestedName) else {
            throw AppleSwiftFileCopyReceiverError.invalidItem
        }
        self.destinationDirectory = destinationDirectory.standardizedFileURL
        self.requestedName = requestedName
        do {
            try FileManager.default.createDirectory(
                at: self.destinationDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
        } catch {
            throw AppleSwiftFileCopyReceiverError.writeFailed
        }
    }

    deinit {
        try? currentItem?.handle.close()
    }

    func receive(_ payload: AppleFileCopyReceiverPayload) throws -> Update {
        guard !didFinish else { throw AppleSwiftFileCopyReceiverError.invalidSequence }
        switch payload {
        case .summary(let summary):
            guard self.summary == nil, currentItem == nil, rootURL == nil else {
                throw AppleSwiftFileCopyReceiverError.invalidSequence
            }
            self.summary = summary
            return Update(progress: summary.logicalBytes == 0 ? 0 : nil, completedURL: nil)
        case .item(let metadata):
            guard summary != nil, currentItem == nil else {
                throw AppleSwiftFileCopyReceiverError.invalidSequence
            }
            try receive(metadata)
            return Update(progress: nil, completedURL: nil)
        case .data(let data):
            return try receive(data)
        case .compressedData(let uncompressedLength, let data):
            let decompressor: ZlibSyncFlushDecompressor
            if let existing = self.decompressor {
                decompressor = existing
            } else {
                do {
                    decompressor = try ZlibSyncFlushDecompressor()
                } catch {
                    throw AppleSwiftFileCopyReceiverError.invalidSequence
                }
                self.decompressor = decompressor
            }
            let decompressed: Data
            do {
                decompressed = try decompressor.decompress(
                    data,
                    expectedSize: uncompressedLength,
                    maximumOutputLength: 65_536
                )
            } catch {
                throw AppleSwiftFileCopyReceiverError.invalidSequence
            }
            return try receive(decompressed)
        case .done(let status):
            if status != 0 {
                didFinish = true
                throw AppleSwiftFileCopyReceiverError.remoteFailed(status)
            }
            guard summary != nil, currentItem == nil, let rootURL, let rootMetadata else {
                throw AppleSwiftFileCopyReceiverError.invalidSequence
            }
            didFinish = true
            try Self.applyMetadata(rootMetadata, to: rootURL, appliesLock: true)
            return Update(progress: 1, completedURL: rootURL)
        }
    }

    private func receive(_ metadata: AppleFileCopyItemMetadata) throws {
        guard Self.isValidComponent(metadata.name),
              metadata.level == 0 ? rootURL == nil : parentDirectories[metadata.level - 1] != nil else {
            throw AppleSwiftFileCopyReceiverError.invalidItem
        }
        if metadata.type == .symbolicLink,
           let target = metadata.symbolicLinkTarget,
           target.count > 0x3ff {
            // The native receiver logs and skips overlong link targets without
            // terminating the surrounding directory transfer.
            parentDirectories = parentDirectories.filter { $0.key < metadata.level }
            return
        }
        let parent = metadata.level == 0
            ? destinationDirectory
            : parentDirectories[metadata.level - 1]!
        let preferredName = metadata.level == 0 ? requestedName : metadata.name
        let url = try Self.createItem(metadata, parent: parent, preferredName: preferredName)
        parentDirectories = parentDirectories.filter { $0.key < metadata.level }
        if metadata.type == .directory {
            parentDirectories[metadata.level] = url
        }
        if metadata.level == 0 {
            rootURL = url
            rootMetadata = metadata
        }

        guard metadata.type != .symbolicLink else { return }
        let hasForkData = metadata.dataForkSize != 0 || metadata.resourceForkSize != 0
        if metadata.level == 0, hasForkData {
            try Self.markRootInProgress(metadata, at: url)
        }
        if metadata.dataForkSize > 0 {
            currentItem = CurrentItem(
                url: url,
                metadata: metadata,
                fork: .data,
                remainingBytes: metadata.dataForkSize,
                handle: try Self.openDataFork(at: url)
            )
            return
        }
        if metadata.resourceForkSize > 0 {
            currentItem = CurrentItem(
                url: url,
                metadata: metadata,
                fork: .resource,
                remainingBytes: metadata.resourceForkSize,
                handle: try Self.openResourceFork(at: url)
            )
            return
        }
        try Self.applyMetadata(metadata, to: url, appliesLock: metadata.level != 0)
        if metadata.level == 0 {
            try Self.markRootInProgress(metadata, at: url)
        }
    }

    private func receive(_ data: Data) throws -> Update {
        guard !data.isEmpty, var currentItem,
              UInt64(data.count) <= currentItem.remainingBytes else {
            throw AppleSwiftFileCopyReceiverError.invalidSequence
        }
        do {
            try currentItem.handle.write(contentsOf: data)
        } catch {
            throw AppleSwiftFileCopyReceiverError.writeFailed
        }
        currentItem.remainingBytes -= UInt64(data.count)
        transferredBytes = transferredBytes.addingReportingOverflow(UInt64(data.count)).partialValue
        if currentItem.remainingBytes == 0 {
            do {
                try currentItem.handle.close()
            } catch {
                throw AppleSwiftFileCopyReceiverError.writeFailed
            }
            if currentItem.fork == .data, currentItem.metadata.resourceForkSize > 0 {
                currentItem.fork = .resource
                currentItem.remainingBytes = currentItem.metadata.resourceForkSize
                currentItem.handle = try Self.openResourceFork(at: currentItem.url)
                self.currentItem = currentItem
            } else {
                try Self.applyMetadata(
                    currentItem.metadata,
                    to: currentItem.url,
                    appliesLock: currentItem.metadata.level != 0
                )
                self.currentItem = nil
            }
        } else {
            self.currentItem = currentItem
        }
        let progress: Double?
        if let total = summary?.logicalBytes, total > 0 {
            progress = min(1, Double(min(transferredBytes, total)) / Double(total))
        } else {
            progress = nil
        }
        return Update(progress: progress, completedURL: nil)
    }

    private static func createItem(
        _ metadata: AppleFileCopyItemMetadata,
        parent: URL,
        preferredName: String
    ) throws -> URL {
        for suffix in 1...65_535 {
            let name = suffix == 1 ? preferredName : uniqueName(preferredName, suffix: suffix)
            guard isValidComponent(name) else { continue }
            let url = parent.appendingPathComponent(name, isDirectory: metadata.type == .directory)
            errno = 0
            switch metadata.type {
            case .file:
                let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                if descriptor >= 0 {
                    close(descriptor)
                    return url
                }
            case .directory:
                if mkdir(url.path, 0o755) == 0 { return url }
            case .symbolicLink:
                guard let target = metadata.symbolicLinkTarget,
                      !target.isEmpty,
                      !target.contains(0) else {
                    throw AppleSwiftFileCopyReceiverError.invalidItem
                }
                var terminatedTarget = target
                terminatedTarget.append(0)
                let result = terminatedTarget.withUnsafeBytes { bytes in
                    url.path.withCString { path in
                        symlink(
                            bytes.bindMemory(to: CChar.self).baseAddress,
                            path
                        )
                    }
                }
                if result == 0 { return url }
            }
            guard errno == EEXIST else {
                throw AppleSwiftFileCopyReceiverError.writeFailed
            }
        }
        throw AppleSwiftFileCopyReceiverError.writeFailed
    }

    private static func uniqueName(_ name: String, suffix: Int) -> String {
        let suffixText = " \(suffix)"
        let url = URL(fileURLWithPath: name)
        let pathExtension = url.pathExtension
        let extensionText = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        let stem = pathExtension.isEmpty
            ? name
            : String(name.dropLast(extensionText.count))
        let maximumStemUnits = max(0, 255 - suffixText.utf16.count - extensionText.utf16.count)
        let truncatedStem = String(stem.utf16.prefix(maximumStemUnits)) ?? stem
        return truncatedStem + suffixText + extensionText
    }

    private static func isValidComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
            && !name.contains("\0") && name.utf16.count <= 255
    }

    private static func openDataFork(at url: URL) throws -> FileHandle {
        do {
            return try FileHandle(forWritingTo: url)
        } catch {
            throw AppleSwiftFileCopyReceiverError.writeFailed
        }
    }

    private static func openResourceFork(at url: URL) throws -> FileHandle {
        let path = url.path + "/..namedfork/rsrc"
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard descriptor >= 0 else { throw AppleSwiftFileCopyReceiverError.writeFailed }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func markRootInProgress(
        _ metadata: AppleFileCopyItemMetadata,
        at url: URL
    ) throws {
        var finderInfo = metadata.finderInfo
        finderInfo.replaceSubrange(0..<4, with: Data("korb".utf8))
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_CRTIME | ATTR_CMN_FNDRINFO)
        var buffer = Data()
        buffer.appendNative(timespec(inProgressDate))
        buffer.append(finderInfo)
        let result = buffer.withUnsafeMutableBytes { bytes in
            setattrlist(
                url.path,
                &attributes,
                bytes.baseAddress,
                bytes.count,
                UInt32(FSOPT_NOFOLLOW)
            )
        }
        guard result == 0 else { throw AppleSwiftFileCopyReceiverError.writeFailed }
    }

    private static func applyMetadata(
        _ metadata: AppleFileCopyItemMetadata,
        to url: URL,
        appliesLock: Bool
    ) throws {
        guard metadata.type != .symbolicLink else { return }
        for attribute in metadata.extendedAttributes {
            guard writeExtendedAttribute(attribute, to: url) else { break }
        }
        try applyCatalogMetadata(metadata, to: url)
        _ = chmod(url.path, mode_t(metadata.mode & 0xf3ff))
        if metadata.level != 0 {
            try applyNodeFlags(metadata.nodeFlags, to: url)
        } else if appliesLock {
            try applyNodeFlags(metadata.nodeFlags & 1, to: url)
        }
    }

    private static func writeExtendedAttribute(
        _ attribute: AppleFileCopyExtendedAttribute,
        to url: URL
    ) -> Bool {
        attribute.value.withUnsafeBytes { bytes in
            url.path.withCString { path in
                attribute.name.withCString { name in
                    setxattr(
                        path,
                        name,
                        bytes.baseAddress,
                        bytes.count,
                        0,
                        XATTR_NOFOLLOW
                    ) == 0
                }
            }
        }
    }

    private static func applyCatalogMetadata(
        _ metadata: AppleFileCopyItemMetadata,
        to url: URL
    ) throws {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(
            ATTR_CMN_SCRIPT | ATTR_CMN_CRTIME | ATTR_CMN_MODTIME | ATTR_CMN_CHGTIME
                | ATTR_CMN_ACCTIME | ATTR_CMN_BKUPTIME | ATTR_CMN_FNDRINFO
        )
        var buffer = Data()
        buffer.appendNative(metadata.textEncodingHint)
        buffer.appendNative(timespec(metadata.creationDate))
        buffer.appendNative(timespec(metadata.contentModificationDate))
        buffer.appendNative(timespec(metadata.attributeModificationDate))
        buffer.appendNative(timespec(metadata.accessDate))
        buffer.appendNative(timespec(metadata.backupDate))
        buffer.append(metadata.finderInfo)
        let result = buffer.withUnsafeMutableBytes { bytes in
            setattrlist(
                url.path,
                &attributes,
                bytes.baseAddress,
                bytes.count,
                UInt32(FSOPT_NOFOLLOW)
            )
        }
        guard result == 0 else { throw AppleSwiftFileCopyReceiverError.writeFailed }
    }

    private static func applyLock(_ locked: Bool, to url: URL) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            throw AppleSwiftFileCopyReceiverError.writeFailed
        }
        let flags = locked ? value.st_flags | UInt32(UF_IMMUTABLE) : value.st_flags & ~UInt32(UF_IMMUTABLE)
        guard chflags(url.path, flags) == 0 else {
            throw AppleSwiftFileCopyReceiverError.writeFailed
        }
    }

    private static func applyNodeFlags(_ nodeFlags: UInt16, to url: URL) throws {
        guard !AppleFileCatalogMetadata.setNodeFlags(nodeFlags, at: url) else { return }
        // FSGet/SetCatalogInfo is public but deprecated. On filesystems where
        // it is unavailable, preserve the only mutable APFS bit and let the
        // created item type provide the derived directory state.
        try applyLock(nodeFlags & 1 != 0, to: url)
    }

    private static func timespec(_ value: AppleFileCopyUTCDateTime) -> Darwin.timespec {
        let macSeconds = Int64(clamping: value.seconds)
        let unixSeconds = macSeconds - macEpochOffset
        let nanoseconds = Int64(value.fraction) * 1_000_000_000 / Int64(UInt16.max)
        return Darwin.timespec(tv_sec: Int(unixSeconds), tv_nsec: Int(nanoseconds))
    }
}

private extension Data {
    mutating func appendNative<T>(_ value: T) {
        var value = value
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
