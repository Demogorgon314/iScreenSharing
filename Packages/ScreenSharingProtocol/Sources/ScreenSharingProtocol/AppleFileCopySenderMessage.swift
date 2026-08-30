import Foundation

public struct AppleFileCopySummary: Equatable, Sendable {
    public let rootIsFile: Bool
    public let logicalBytes: UInt64
    public let physicalBytes: UInt64
    public let fileCount: UInt64
    public let folderCount: UInt64

    public init(
        rootIsFile: Bool,
        logicalBytes: UInt64,
        physicalBytes: UInt64,
        fileCount: UInt64,
        folderCount: UInt64
    ) {
        self.rootIsFile = rootIsFile
        self.logicalBytes = logicalBytes
        self.physicalBytes = physicalBytes
        self.fileCount = fileCount
        self.folderCount = folderCount
    }
}

public struct AppleFileCopyUTCDateTime: Equatable, Sendable {
    public let seconds: UInt64
    public let fraction: UInt16

    public init(seconds: UInt64, fraction: UInt16) {
        self.seconds = seconds
        self.fraction = fraction
    }

    public static let zero = AppleFileCopyUTCDateTime(seconds: 0, fraction: 0)
}

public enum AppleFileCopyItemType: UInt8, Equatable, Sendable {
    case file = 1
    case directory = 2
    case symbolicLink = 3
}

public struct AppleFileCopyExtendedAttribute: Equatable, Sendable {
    public let name: String
    public let value: Data

    public init(name: String, value: Data) {
        self.name = name
        self.value = value
    }
}

public struct AppleFileCopyItemMetadata: Equatable, Sendable {
    public let type: AppleFileCopyItemType
    public let userAccess: UInt8
    public let finderInfo: Data
    public let resourceForkSize: UInt64
    public let dataForkSize: UInt64
    public let creationDate: AppleFileCopyUTCDateTime
    public let contentModificationDate: AppleFileCopyUTCDateTime
    public let attributeModificationDate: AppleFileCopyUTCDateTime
    public let accessDate: AppleFileCopyUTCDateTime
    public let backupDate: AppleFileCopyUTCDateTime
    public let nodeFlags: UInt16
    public let level: UInt16
    public let mode: UInt16
    public let textEncodingHint: UInt32
    public let name: String
    public let symbolicLinkTarget: Data?
    public let extendedAttributes: [AppleFileCopyExtendedAttribute]

    public init(
        type: AppleFileCopyItemType,
        userAccess: UInt8 = 0,
        finderInfo: Data,
        resourceForkSize: UInt64,
        dataForkSize: UInt64,
        creationDate: AppleFileCopyUTCDateTime,
        contentModificationDate: AppleFileCopyUTCDateTime,
        attributeModificationDate: AppleFileCopyUTCDateTime,
        accessDate: AppleFileCopyUTCDateTime,
        backupDate: AppleFileCopyUTCDateTime = .zero,
        nodeFlags: UInt16,
        level: UInt16,
        mode: UInt16,
        textEncodingHint: UInt32,
        name: String,
        symbolicLinkTarget: Data? = nil,
        extendedAttributes: [AppleFileCopyExtendedAttribute] = []
    ) {
        self.type = type
        self.userAccess = userAccess
        self.finderInfo = finderInfo
        self.resourceForkSize = resourceForkSize
        self.dataForkSize = dataForkSize
        self.creationDate = creationDate
        self.contentModificationDate = contentModificationDate
        self.attributeModificationDate = attributeModificationDate
        self.accessDate = accessDate
        self.backupDate = backupDate
        self.nodeFlags = nodeFlags
        self.level = level
        self.mode = mode
        self.textEncodingHint = textEncodingHint
        self.name = name
        self.symbolicLinkTarget = symbolicLinkTarget
        self.extendedAttributes = extendedAttributes
    }
}

public extension AppleFileTransferMessage {
    static func senderSummary(sessionID: UInt32, summary: AppleFileCopySummary) throws -> Data {
        guard sessionID != 0 else { throw AppleFileTransferError.invalidMessage }
        var body = senderBody(command: 100, sessionID: sessionID)
        body.appendUInt32BE(summary.rootIsFile ? 1 : 0)
        body.appendUInt32BE(0)
        body.appendUInt64BE(summary.logicalBytes)
        body.appendUInt64BE(summary.physicalBytes)
        body.appendUInt64BE(summary.fileCount)
        body.appendUInt64BE(0)
        body.appendUInt64BE(summary.folderCount)
        body.appendUInt32BE(0)
        return senderMessage(body: body)
    }

    /// Builds the native tool-only progress preamble. Its envelope length and
    /// summary values use host byte order even though version/command/session
    /// retain their wire byte order.
    static func senderItemInfo(sessionID: UInt32, summary: AppleFileCopySummary) throws -> Data {
        guard sessionID != 0 else { throw AppleFileTransferError.invalidMessage }
        var message = Data([0x22, 0])
        message.appendUInt32LE(60)
        message.appendUInt16BE(1)
        message.appendUInt16BE(100)
        message.appendUInt32BE(sessionID)
        message.appendUInt32LE(summary.rootIsFile ? 0 : 1)
        message.appendUInt32LE(0)
        message.appendUInt64LE(summary.logicalBytes)
        message.appendUInt64LE(summary.physicalBytes)
        message.appendUInt64LE(summary.fileCount)
        message.appendUInt64LE(0)
        message.appendUInt64LE(summary.folderCount)
        message.appendUInt32LE(0)
        return message
    }

    static func senderItem(sessionID: UInt32, item: AppleFileCopyItemMetadata) throws -> Data {
        let name = Data(item.name.precomposedStringWithCanonicalMapping.utf8)
        let linkTarget = item.symbolicLinkTarget ?? Data()
        guard sessionID != 0,
              item.finderInfo.count == 32,
              !name.isEmpty,
              !name.contains(0),
              name.count <= Int(UInt16.max),
              item.type == .symbolicLink ? !linkTarget.isEmpty : linkTarget.isEmpty,
              linkTarget.count <= Int(UInt16.max) else {
            throw AppleFileTransferError.invalidMessage
        }
        if item.type == .symbolicLink,
           name.count + 1 + linkTarget.count > 1_279 {
            throw AppleFileTransferError.payloadTooLarge
        }

        var body = senderBody(command: 101, sessionID: sessionID)
        body.append(item.type.rawValue)
        body.append(item.userAccess)
        var finderInfo = item.finderInfo
        // The native sender forgets to byte-swap extFinderInfo[8...9]. The
        // receiver ignores these two bytes, but preserving the quirk keeps
        // sender vectors byte-for-byte compatible.
        finderInfo.swapAt(24, 25)
        body.append(finderInfo)
        body.appendUInt64BE(item.resourceForkSize)
        body.appendUInt64BE(item.dataForkSize)
        body.appendUTCDateTime(item.creationDate)
        body.appendUTCDateTime(item.contentModificationDate)
        body.appendUTCDateTime(item.attributeModificationDate)
        body.appendUTCDateTime(item.accessDate)
        body.appendUTCDateTime(item.backupDate)
        body.appendUInt16BE(item.nodeFlags)
        body.appendUInt16BE(item.level)
        body.appendUInt16BE(item.mode)
        body.appendUInt32BE(item.textEncodingHint)
        body.appendUInt16BE(UInt16(name.count))
        body.appendUInt16BE(linkTarget.isEmpty ? 0 : UInt16(linkTarget.count - 1))
        body.append(name)
        body.append(0)
        body.append(linkTarget)
        if let attributes = try senderExtendedAttributes(item.extendedAttributes),
           body.count + attributes.count <= 0xefff {
            body.append(attributes)
        }
        guard body.count <= maximumFileCopyBodyLength else {
            throw AppleFileTransferError.payloadTooLarge
        }
        return senderMessage(body: body)
    }

    static func senderData(sessionID: UInt32, data: Data) throws -> Data {
        guard sessionID != 0, !data.isEmpty, data.count <= 65_536 else {
            throw AppleFileTransferError.invalidMessage
        }
        var body = senderBody(command: 102, sessionID: sessionID)
        body.appendUInt32BE(UInt32(data.count))
        body.append(data)
        return senderMessage(body: body)
    }

    static func senderCompressedData(
        sessionID: UInt32,
        uncompressedLength: Int,
        data: Data
    ) throws -> Data {
        guard sessionID != 0,
              (1...65_536).contains(uncompressedLength),
              !data.isEmpty,
              data.count <= maximumFileCopyBodyLength - 18 else {
            throw AppleFileTransferError.invalidMessage
        }
        var body = senderBody(command: 103, sessionID: sessionID)
        body.appendUInt16BE(1)
        body.appendUInt32BE(UInt32(uncompressedLength))
        body.appendUInt32BE(UInt32(data.count))
        body.append(data)
        return senderMessage(body: body)
    }

    static func senderDone(sessionID: UInt32, status: Int32) throws -> Data {
        guard sessionID != 0 else { throw AppleFileTransferError.invalidMessage }
        var body = senderBody(command: 104, sessionID: sessionID)
        body.appendUInt32LE(UInt32(bitPattern: status))
        return senderMessage(body: body)
    }

    private static func senderBody(command: UInt16, sessionID: UInt32) -> Data {
        var body = Data()
        body.appendUInt16BE(1)
        body.appendUInt16BE(command)
        body.appendUInt32BE(sessionID)
        return body
    }

    private static func senderMessage(body: Data) -> Data {
        var message = Data([0x22, 0])
        message.appendUInt32BE(UInt32(body.count))
        message.append(body)
        return message
    }

    private static func senderExtendedAttributes(
        _ attributes: [AppleFileCopyExtendedAttribute]
    ) throws -> Data? {
        guard !attributes.isEmpty else { return nil }
        let encoded = try attributes.map { attribute -> (name: Data, value: Data) in
            let name = Data(attribute.name.utf8)
            guard !name.isEmpty, !name.contains(0), name.count < Int(UInt32.max),
                  attribute.value.count <= Int(UInt32.max) else {
                throw AppleFileTransferError.invalidMessage
            }
            return (name, attribute.value)
        }
        var blob = Data()
        blob.appendUInt32BE(0)
        blob.appendUInt32BE(UInt32(encoded.count))
        for attribute in encoded {
            blob.appendUInt32BE(UInt32(attribute.name.count + 1))
            blob.appendUInt32BE(UInt32(attribute.value.count))
        }
        for attribute in encoded {
            blob.append(attribute.name)
            blob.append(0)
            blob.append(attribute.value)
        }
        guard blob.count <= Int(UInt32.max), blob.count + 10 <= Int(UInt16.max) else {
            return nil
        }
        blob.replaceSubrange(0..<4, with: UInt32(blob.count).bigEndianBytes)
        var record = Data("ext1".utf8)
        record.appendUInt16BE(0)
        record.appendUInt16BE(1)
        record.appendUInt16BE(UInt16(blob.count + 10))
        record.append(blob)
        return record
    }
}

private extension Data {
    mutating func appendUInt16BE(_ value: UInt16) {
        BigEndianWire.append(value, to: &self)
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        BigEndianWire.append(value, to: &self)
    }

    mutating func appendUInt64BE(_ value: UInt64) {
        appendUInt32BE(UInt32(truncatingIfNeeded: value >> 32))
        appendUInt32BE(UInt32(truncatingIfNeeded: value))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    mutating func appendUInt64LE(_ value: UInt64) {
        appendUInt32LE(UInt32(truncatingIfNeeded: value))
        appendUInt32LE(UInt32(truncatingIfNeeded: value >> 32))
    }

    mutating func appendUTCDateTime(_ value: AppleFileCopyUTCDateTime) {
        appendUInt16BE(UInt16(truncatingIfNeeded: value.seconds >> 32))
        appendUInt32BE(UInt32(truncatingIfNeeded: value.seconds))
        appendUInt16BE(value.fraction)
    }
}

private extension UInt32 {
    var bigEndianBytes: Data {
        Data([
            UInt8(truncatingIfNeeded: self >> 24),
            UInt8(truncatingIfNeeded: self >> 16),
            UInt8(truncatingIfNeeded: self >> 8),
            UInt8(truncatingIfNeeded: self),
        ])
    }
}
