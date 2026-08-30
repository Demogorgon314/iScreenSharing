import Darwin
import Foundation
import enum ScreenSharingProtocol.AppleFileCopyItemType
import struct ScreenSharingProtocol.AppleFileCopyExtendedAttribute
import struct ScreenSharingProtocol.AppleFileCopyItemMetadata
import struct ScreenSharingProtocol.AppleFileCopySummary
import enum ScreenSharingProtocol.AppleFileCopyToolOutput
import struct ScreenSharingProtocol.AppleFileCopyUTCDateTime
import enum ScreenSharingProtocol.AppleFileTransferMessage
import class ScreenSharingProtocol.ZlibSyncFlushCompressor

struct AppleSwiftFileCopySender: AppleFileCopySenderRunning {
    private struct FileSystemFailure: Error {
        let status: Int32
    }

    private struct TransferItem {
        let path: String
        let type: AppleFileCopyItemType
        let level: UInt16
    }

    private struct PhysicalTreeEntry {
        let path: String
        let info: Int32
        let level: Int16
    }

    private struct CatalogAttributeBuffer {
        var length: UInt32 = 0
        var textEncodingHint: UInt32 = 0
        var backupTime = timespec()
    }

    private final class PhysicalTree {
        private let pathPointer: UnsafeMutablePointer<CChar>
        private let tree: UnsafeMutablePointer<FTS>

        init(path: String) throws {
            guard let pathPointer = strdup(path) else {
                throw FileSystemFailure(status: -1)
            }
            var paths: [UnsafeMutablePointer<CChar>?] = [pathPointer, nil]
            guard let tree = fts_open(&paths, FTS_PHYSICAL | FTS_XDEV, nil) else {
                free(pathPointer)
                throw failureForCurrentErrno()
            }
            self.pathPointer = pathPointer
            self.tree = tree
        }

        deinit {
            fts_close(tree)
            free(pathPointer)
        }

        func next() throws -> PhysicalTreeEntry? {
            errno = 0
            guard let entry = fts_read(tree) else {
                if errno != 0 { throw failureForCurrentErrno() }
                return nil
            }
            return PhysicalTreeEntry(
                path: String(cString: entry.pointee.fts_path),
                info: Int32(entry.pointee.fts_info),
                level: entry.pointee.fts_level
            )
        }
    }

    private final class CompressionContext {
        private var policy: AppleFileCopyCompressionPolicy
        private var compressor: ZlibSyncFlushCompressor?
        private let tickCount: @Sendable () -> UInt32

        init(startTick: UInt32, tickCount: @escaping @Sendable () -> UInt32) {
            policy = AppleFileCopyCompressionPolicy(startTick: startTick)
            self.tickCount = tickCount
        }

        func message(
            for data: Data,
            fileName: String,
            sessionID: UInt32,
            outputPipe: AppleFileCopyOutputPipe
        ) async throws -> Data {
            let metrics = await outputPipe.metrics()
            guard policy.shouldCompress(
                fileName: fileName,
                pendingBytes: metrics.pendingBytes,
                totalBytesSent: metrics.totalBytesEnqueued,
                currentTick: tickCount()
            ) else {
                return try AppleFileTransferMessage.senderData(
                    sessionID: sessionID,
                    data: data
                )
            }
            let compressor: ZlibSyncFlushCompressor
            if let existing = self.compressor {
                compressor = existing
            } else {
                let created: ZlibSyncFlushCompressor
                do {
                    created = try ZlibSyncFlushCompressor()
                } catch {
                    throw FileSystemFailure(status: -500)
                }
                self.compressor = created
                compressor = created
            }
            let compressed: Data
            do {
                compressed = try compressor.compress(data)
            } catch {
                throw FileSystemFailure(status: -502)
            }
            policy.recordCompressedBlock(
                inputBytes: data.count,
                outputBytes: compressed.count
            )
            return try AppleFileTransferMessage.senderCompressedData(
                sessionID: sessionID,
                uncompressedLength: data.count,
                data: compressed
            )
        }
    }

    private static let chunkSize = 65_536
    private static let macEpochOffset: Int64 = 2_082_844_800
    private static let transferableXAttrs = [
        "com.apple.quarantine",
        "com.apple.metadata:kMDItemWhereFroms",
    ]

    private let tickCount: @Sendable () -> UInt32

    init(
        tickCount: @escaping @Sendable () -> UInt32 = {
            AppleSwiftFileCopySender.currentTick()
        }
    ) {
        self.tickCount = tickCount
    }

    let isAvailable = true

    func run(
        for fileURL: URL,
        sessionID: UInt32,
        receive: @escaping @Sendable (AppleFileCopyToolOutput) async throws -> Void
    ) async throws {
        let outputPipe = AppleFileCopyOutputPipe(receive: receive)
        let compression = CompressionContext(
            startTick: tickCount(),
            tickCount: tickCount
        )
        do {
            let status: Int32
            do {
                let rootPath = try Self.resolvedRootPath(fileURL.path)
                let rootStat = try Self.fileStat(rootPath)
                let summary = try Self.summary(
                    sourcePath: fileURL.path,
                    rootIsFile: !Self.isDirectory(rootStat)
                )
                try await outputPipe.send(.frame(
                    try AppleFileTransferMessage.senderSummary(
                        sessionID: sessionID,
                        summary: summary
                    )
                ))
                try await outputPipe.send(.itemInfo(
                    try AppleFileTransferMessage.senderItemInfo(
                        sessionID: sessionID,
                        summary: summary
                    )
                ))
                if Self.isDirectory(rootStat) {
                    try await sendDirectory(
                        path: rootPath,
                        sessionID: sessionID,
                        compression: compression,
                        outputPipe: outputPipe
                    )
                } else {
                    try await send(
                        TransferItem(path: rootPath, type: .file, level: 0),
                        sessionID: sessionID,
                        compression: compression,
                        outputPipe: outputPipe
                    )
                }
                status = 0
            } catch let failure as FileSystemFailure {
                status = failure.status
            }

            try await outputPipe.send(.frame(
                try AppleFileTransferMessage.senderDone(
                    sessionID: sessionID,
                    status: status
                )
            ))
            try await outputPipe.send(.finished(
                status: UInt16(truncatingIfNeeded: status)
            ))
            try await outputPipe.finish()
        } catch {
            await outputPipe.cancel()
            throw error
        }
    }

    private func sendDirectory(
        path: String,
        sessionID: UInt32,
        compression: CompressionContext,
        outputPipe: AppleFileCopyOutputPipe
    ) async throws {
        let tree = try PhysicalTree(path: path)
        while let entry = try tree.next() {
            guard let item = try Self.transferItem(from: entry) else { continue }
            try await send(
                item,
                sessionID: sessionID,
                compression: compression,
                outputPipe: outputPipe
            )
        }
    }

    private static func transferItem(from entry: PhysicalTreeEntry) throws -> TransferItem? {
        let type: AppleFileCopyItemType
        switch entry.info {
        case FTS_D:
            type = .directory
        case FTS_F:
            type = .file
        case FTS_SL, FTS_SLNONE:
            type = .symbolicLink
        case FTS_DNR, FTS_ERR, FTS_NS:
            throw FileSystemFailure(status: -1)
        default:
            return nil
        }
        guard entry.level >= 0 else { throw FileSystemFailure(status: -1) }
        return TransferItem(
            path: entry.path,
            type: type,
            level: UInt16(entry.level)
        )
    }

    private func send(
        _ item: TransferItem,
        sessionID: UInt32,
        compression: CompressionContext,
        outputPipe: AppleFileCopyOutputPipe
    ) async throws {
        try Task.checkCancellation()
        let metadata = try Self.metadata(for: item)
        try await outputPipe.send(.frame(try AppleFileTransferMessage.senderItem(
            sessionID: sessionID,
            item: metadata
        )))
        guard item.type == .file else { return }
        try await sendFork(
            path: item.path,
            expectedSize: metadata.dataForkSize,
            fileName: metadata.name,
            sessionID: sessionID,
            compression: compression,
            outputPipe: outputPipe
        )
        if metadata.resourceForkSize > 0 {
            try await sendFork(
                path: item.path + "/..namedfork/rsrc",
                expectedSize: metadata.resourceForkSize,
                fileName: metadata.name,
                sessionID: sessionID,
                compression: compression,
                outputPipe: outputPipe
            )
        }
    }

    private func sendFork(
        path: String,
        expectedSize: UInt64,
        fileName: String,
        sessionID: UInt32,
        compression: CompressionContext,
        outputPipe: AppleFileCopyOutputPipe
    ) async throws {
        guard expectedSize > 0 else { return }
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.failureForCurrentErrno() }
        defer { Darwin.close(descriptor) }

        var remaining = expectedSize
        var buffer = [UInt8](repeating: 0, count: Self.chunkSize)
        while remaining > 0 {
            try Task.checkCancellation()
            let requested = min(Self.chunkSize, Int(remaining))
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, requested)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw Self.failureForCurrentErrno()
            }
            guard count > 0 else { throw FileSystemFailure(status: -1) }
            let data = Data(buffer[0..<count])
            let message = try await compression.message(
                for: data,
                fileName: fileName,
                sessionID: sessionID,
                outputPipe: outputPipe
            )
            try await outputPipe.send(.frame(message))
            remaining -= UInt64(count)
        }
    }

    private static func summary(
        sourcePath: String,
        rootIsFile: Bool
    ) throws -> AppleFileCopySummary {
        var logicalBytes: UInt64 = 0
        var physicalBytes: UInt64 = 0
        var fileCount: UInt64 = 0
        var folderCount: UInt64 = 0
        let tree = try PhysicalTree(path: sourcePath)
        while let entry = try tree.next() {
            switch entry.info {
            case FTS_D:
                folderCount = try adding(folderCount, 1)
            case FTS_F, FTS_SL, FTS_SLNONE:
                let value = try fileStat(entry.path)
                fileCount = try adding(fileCount, 1)
                if isSymbolicLink(value) {
                    logicalBytes = try adding(logicalBytes, UInt64(max(0, value.st_size)))
                } else {
                    logicalBytes = try adding(logicalBytes, UInt64(max(0, value.st_size)))
                    logicalBytes = try adding(logicalBytes, resourceForkSize(entry.path))
                    physicalBytes = try adding(
                        physicalBytes,
                        try dataForkPhysicalSize(entry.path)
                    )
                }
            case FTS_DNR, FTS_ERR, FTS_NS:
                throw FileSystemFailure(status: -1)
            default:
                break
            }
        }
        return AppleFileCopySummary(
            rootIsFile: rootIsFile,
            logicalBytes: logicalBytes,
            physicalBytes: physicalBytes,
            fileCount: fileCount,
            folderCount: folderCount
        )
    }

    private static func metadata(for item: TransferItem) throws -> AppleFileCopyItemMetadata {
        let value = try fileStat(item.path)
        let catalogAttributes = try catalogAttributes(item.path)
        let linkTarget = item.type == .symbolicLink ? try symbolicLinkTarget(item.path) : nil
        let dataSize: UInt64
        switch item.type {
        case .directory:
            dataSize = 0
        case .symbolicLink:
            dataSize = UInt64(linkTarget?.count ?? 0)
        case .file:
            dataSize = UInt64(max(0, value.st_size))
        }
        let resourceSize = item.type == .file ? resourceForkSize(item.path) : 0
        let name = URL(fileURLWithPath: item.path).lastPathComponent
        guard !name.isEmpty else { throw FileSystemFailure(status: -1) }
        if item.type == .symbolicLink,
           name.utf8.count + 1 + Int(dataSize) > 1_279 {
            throw FileSystemFailure(status: -20)
        }

        return AppleFileCopyItemMetadata(
            type: item.type,
            finderInfo: finderInfo(path: item.path, type: item.type),
            resourceForkSize: resourceSize,
            dataForkSize: dataSize,
            creationDate: utcDateTime(value.st_birthtimespec),
            contentModificationDate: utcDateTime(value.st_mtimespec),
            attributeModificationDate: utcDateTime(value.st_ctimespec),
            accessDate: utcDateTime(value.st_atimespec),
            backupDate: backupUTCDateTime(catalogAttributes.backupTime),
            nodeFlags: nodeFlags(at: item.path, value: value, type: item.type),
            level: item.level,
            mode: UInt16(truncatingIfNeeded: value.st_mode),
            textEncodingHint: catalogAttributes.textEncodingHint,
            name: name,
            symbolicLinkTarget: linkTarget,
            extendedAttributes: item.type == .symbolicLink
                ? []
                : transferableExtendedAttributes(item.path)
        )
    }

    private static func resolvedRootPath(_ path: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { throw failureForCurrentErrno() }
        return String(cString: buffer)
    }

    private static func fileStat(_ path: String) throws -> Darwin.stat {
        var value = Darwin.stat()
        guard Darwin.lstat(path, &value) == 0 else { throw failureForCurrentErrno() }
        return value
    }

    private static func catalogAttributes(_ path: String) throws -> CatalogAttributeBuffer {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_SCRIPT | ATTR_CMN_BKUPTIME)
        var buffer = CatalogAttributeBuffer()
        let result = withUnsafeMutableBytes(of: &buffer) { bytes in
            getattrlist(
                path,
                &attributes,
                bytes.baseAddress,
                bytes.count,
                UInt32(FSOPT_NOFOLLOW)
            )
        }
        guard result == 0,
              buffer.length <= UInt32(MemoryLayout<CatalogAttributeBuffer>.size) else {
            throw failureForCurrentErrno()
        }
        return buffer
    }

    private static func isDirectory(_ value: Darwin.stat) -> Bool {
        value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }

    private static func isSymbolicLink(_ value: Darwin.stat) -> Bool {
        value.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK)
    }

    private static func symbolicLinkTarget(_ path: String) throws -> Data {
        let value = try fileStat(path)
        var buffer = [CChar](repeating: 0, count: max(Int(value.st_size) + 1, Int(PATH_MAX)))
        let count = buffer.withUnsafeMutableBufferPointer { bytes in
            Darwin.readlink(path, bytes.baseAddress, bytes.count)
        }
        guard count > 0 else { throw failureForCurrentErrno() }
        return Data(bytes: buffer, count: count)
    }

    private static func finderInfo(path: String, type: AppleFileCopyItemType) -> Data {
        if type == .symbolicLink {
            var value = Data("slnkrhap".utf8)
            value.append(contentsOf: [0x80, 0x00])
            value.append(Data(repeating: 0, count: 22))
            return value
        }
        guard let attribute = extendedAttribute("com.apple.FinderInfo", path: path),
              attribute.count >= 32 else {
            return Data(repeating: 0, count: 32)
        }
        return Data(attribute.prefix(32))
    }

    private static func transferableExtendedAttributes(
        _ path: String
    ) -> [AppleFileCopyExtendedAttribute] {
        transferableXAttrs.compactMap { name in
            extendedAttribute(name, path: path).map {
                AppleFileCopyExtendedAttribute(name: name, value: $0)
            }
        }
    }

    private static func extendedAttribute(_ name: String, path: String) -> Data? {
        let size = path.withCString { pathPointer in
            name.withCString { namePointer in
                getxattr(pathPointer, namePointer, nil, 0, 0, XATTR_NOFOLLOW)
            }
        }
        guard size >= 0 else { return nil }
        var value = Data(count: size)
        let count = value.withUnsafeMutableBytes { buffer in
            path.withCString { pathPointer in
                name.withCString { namePointer in
                    getxattr(
                        pathPointer,
                        namePointer,
                        buffer.baseAddress,
                        buffer.count,
                        0,
                        XATTR_NOFOLLOW
                    )
                }
            }
        }
        guard count == size else { return nil }
        return value
    }

    private static func resourceForkSize(_ path: String) -> UInt64 {
        let size = path.withCString { pathPointer in
            "com.apple.ResourceFork".withCString { namePointer in
                getxattr(pathPointer, namePointer, nil, 0, 0, XATTR_NOFOLLOW)
            }
        }
        return size > 0 ? UInt64(size) : 0
    }

    private static func dataForkPhysicalSize(_ path: String) throws -> UInt64 {
        do {
            let values = try URL(fileURLWithPath: path).resourceValues(
                forKeys: [.fileAllocatedSizeKey]
            )
            guard let size = values.fileAllocatedSize, size >= 0 else {
                throw FileSystemFailure(status: -1)
            }
            return UInt64(size)
        } catch let failure as FileSystemFailure {
            throw failure
        } catch {
            throw FileSystemFailure(status: -1)
        }
    }

    private static func nodeFlags(
        at path: String,
        value: Darwin.stat,
        type: AppleFileCopyItemType
    ) -> UInt16 {
        AppleFileCatalogMetadata.nodeFlags(at: URL(fileURLWithPath: path))
            ?? fallbackNodeFlags(value, type: type)
    }

    private static func fallbackNodeFlags(
        _ value: Darwin.stat,
        type: AppleFileCopyItemType
    ) -> UInt16 {
        var flags: UInt16 = type == .directory ? 0x10 : 0
        if value.st_flags & UInt32(UF_IMMUTABLE) != 0 { flags |= 0x01 }
        return flags
    }

    private static func utcDateTime(_ value: timespec) -> AppleFileCopyUTCDateTime {
        let seconds = max(0, Int64(value.tv_sec) + macEpochOffset)
        let nanoseconds = max(0, min(999_999_999, Int64(value.tv_nsec)))
        return AppleFileCopyUTCDateTime(
            seconds: UInt64(seconds),
            // FSGetCatalogInfo scales the closed UInt16 fraction range rather
            // than using 65,536 units. This preserves its observed wire value
            // when converting the POSIX nanosecond representation back.
            fraction: UInt16(nanoseconds * Int64(UInt16.max) / 1_000_000_000)
        )
    }

    private static func backupUTCDateTime(
        _ value: timespec
    ) -> AppleFileCopyUTCDateTime {
        // FSGetCatalogInfo represents an unset backup date as wire zero. The
        // attrlist equivalent returns timespec(0, 0), which otherwise looks
        // like the valid Unix epoch and would incorrectly add the 1904 offset.
        guard value.tv_sec != 0 || value.tv_nsec != 0 else { return .zero }
        return utcDateTime(value)
    }

    private static func failureForCurrentErrno() -> FileSystemFailure {
        switch errno {
        case ENOENT:
            FileSystemFailure(status: -43)
        case EACCES, EPERM:
            FileSystemFailure(status: -5_000)
        default:
            FileSystemFailure(status: -1)
        }
    }

    private static func adding(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw FileSystemFailure(status: -1) }
        return result
    }

    private static func currentTick() -> UInt32 {
        let nanoseconds = DispatchTime.now().uptimeNanoseconds
        let seconds = nanoseconds / 1_000_000_000
        let remainder = nanoseconds % 1_000_000_000
        let ticks = seconds * 60 + remainder * 60 / 1_000_000_000
        return UInt32(truncatingIfNeeded: ticks)
    }

}
