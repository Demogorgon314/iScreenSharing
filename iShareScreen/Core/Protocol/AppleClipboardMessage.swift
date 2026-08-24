import Foundation

struct AppleClipboardArchive: Equatable, Sendable {
    let items: [AppleClipboardItem]

    static func text(_ text: String) -> AppleClipboardArchive {
        AppleClipboardArchive(items: [
            AppleClipboardItem(flavors: [
                AppleClipboardFlavor(
                    type: AppleClipboardMessage.textType,
                    aliases: [],
                    value: Data(text.utf8)
                )
            ])
        ])
    }

    var preferredText: String? {
        for item in items {
            for flavor in item.flavors {
                if flavor.type == AppleClipboardMessage.textType {
                    return String(decoding: flavor.value, as: UTF8.self)
                }
            }
        }
        return nil
    }
}

struct AppleClipboardItem: Equatable, Sendable {
    let flavors: [AppleClipboardFlavor]
}

struct AppleClipboardFlavor: Equatable, Sendable {
    let type: String
    let aliases: [AppleClipboardTypeAlias]
    let value: Data
}

struct AppleClipboardTypeAlias: Equatable, Sendable {
    let tagClass: String
    let preferredTag: String
}

struct AppleClipboardEnvelope: Equatable, Sendable {
    let sessionID: UInt32
    let containsPromises: Bool
    let archive: AppleClipboardArchive
}

struct AppleClipboardRequest: Equatable, Sendable {
    let requestsPromises: Bool
    let sessionID: UInt32
}

enum AppleClipboardMessage {
    static let maximumPayloadLength = 7 * 1_024 * 1_024
    static let maximumArchiveLength = 64 * 1_024 * 1_024
    static let maximumItemCount = 1_024
    static let maximumFlavorCount = 4_096
    static let maximumAliasCount = 8_192
    static let maximumMetadataLength = 4_096
    static let maximumMetadataBytes = 1 * 1_024 * 1_024
    static let textType = "public.utf8-plain-text"

    static let enable = Data([0x15, 0x00, 0x00, 0x01, 0, 0, 0, 0])
    static let disable = Data([0x15, 0x00, 0x00, 0x02, 0, 0, 0, 0])
    static let fetch = request(promises: false, sessionID: 0)

    static func request(promises: Bool, sessionID: UInt32) -> Data {
        var message = Data([0x0b, promises ? 1 : 0, 0, 0])
        message.appendUInt32BE(sessionID)
        return message
    }

    static func request(from message: Data) -> AppleClipboardRequest? {
        guard message.count >= 8, message[0] == 0x0b,
              let sessionID = try? message.uint32BE(at: 4) else { return nil }
        return AppleClipboardRequest(requestsPromises: message[1] != 0, sessionID: sessionID)
    }

    static func send(text: String) throws -> Data {
        try send(archive: .text(text))
    }

    static func send(
        archive: AppleClipboardArchive,
        promises: Bool = false,
        sessionID: UInt32 = 0
    ) throws -> Data {
        let archiveData = try packedData(for: archive, promises: promises)
        guard archiveData.count <= maximumArchiveLength else {
            throw AppleClipboardError.payloadTooLarge
        }
        let compressed = try ZlibCodec.compress(
            archiveData,
            maximumOutputLength: maximumPayloadLength
        )
        guard compressed.count <= maximumPayloadLength else {
            throw AppleClipboardError.payloadTooLarge
        }

        var message = Data([0x1f, 0, promises ? 1 : 0, 0])
        message.appendUInt32BE(sessionID)
        message.appendUInt32BE(UInt32(archiveData.count))
        message.appendUInt32BE(UInt32(compressed.count))
        message.append(compressed)
        return message
    }

    static func envelope(from message: Data) throws -> AppleClipboardEnvelope {
        guard message.count >= 16, message[0] == 0x1f else {
            throw AppleClipboardError.invalidMessage
        }
        let sessionID = try message.uint32BE(at: 4)
        let uncompressedSize = try Int(message.uint32BE(at: 8))
        let compressedSize = try Int(message.uint32BE(at: 12))
        guard uncompressedSize <= maximumArchiveLength,
              compressedSize <= maximumPayloadLength,
              compressedSize <= message.count - 16 else {
            throw AppleClipboardError.payloadTooLarge
        }
        let payload = message.subdata(in: 16..<(16 + compressedSize))
        let packed = try ZlibCodec.decompressSyncFlush(
            payload,
            expectedSize: uncompressedSize,
            maximumOutputLength: maximumArchiveLength
        )
        guard packed.count == uncompressedSize else { throw AppleClipboardError.invalidMessage }
        return AppleClipboardEnvelope(
            sessionID: sessionID,
            containsPromises: message[2] != 0,
            archive: try unpackedArchive(from: packed)
        )
    }

    static func archive(from message: Data) throws -> AppleClipboardArchive {
        try envelope(from: message).archive
    }

    static func text(from message: Data) throws -> String? {
        try archive(from: message).preferredText
    }

    static func expectedLength(ofFirstFragment fragment: Data) throws -> Int? {
        guard fragment.first == 0x1f else { return nil }
        guard fragment.count >= 16 else { return nil }
        let compressedSize = try Int(fragment.uint32BE(at: 12))
        guard compressedSize <= maximumPayloadLength else { throw AppleClipboardError.payloadTooLarge }
        return 16 + compressedSize
    }

    static func fragments(of message: Data, maximumLength: Int = 60_000) -> [Data] {
        guard maximumLength > 0 else { return [] }
        return stride(from: 0, to: message.count, by: maximumLength).map { offset in
            message.subdata(in: offset..<min(offset + maximumLength, message.count))
        }
    }

    private static func packedData(
        for archive: AppleClipboardArchive,
        promises: Bool
    ) throws -> Data {
        guard archive.items.count <= maximumItemCount else {
            throw AppleClipboardError.invalidMessage
        }
        var data = Data()
        var totalFlavorCount = 0
        var totalAliasCount = 0
        var metadataBytes = 0
        for item in archive.items {
            totalFlavorCount += item.flavors.count
            guard totalFlavorCount <= maximumFlavorCount else {
                throw AppleClipboardError.invalidMessage
            }
            data.appendUInt32BE(UInt32(item.flavors.count))
            for flavor in item.flavors {
                let type = Data(flavor.type.utf8)
                try validateMetadata(type, total: &metadataBytes)
                try data.appendClipboardData(type)
                data.appendUInt32BE(0)
                totalAliasCount += flavor.aliases.count
                guard totalAliasCount <= maximumAliasCount,
                      !flavor.type.isEmpty || !flavor.aliases.isEmpty else {
                    throw AppleClipboardError.invalidMessage
                }
                data.appendUInt32BE(UInt32(flavor.aliases.count))
                for alias in flavor.aliases {
                    let tagClass = Data(alias.tagClass.utf8)
                    let preferredTag = Data(alias.preferredTag.utf8)
                    try validateMetadata(tagClass, total: &metadataBytes)
                    try validateMetadata(preferredTag, total: &metadataBytes)
                    try data.appendClipboardData(tagClass)
                    try data.appendClipboardData(preferredTag)
                }
                try data.appendClipboardData(promises ? Data() : flavor.value)
            }
        }
        return data
    }

    private static func unpackedArchive(from data: Data) throws -> AppleClipboardArchive {
        var reader = ClipboardArchiveReader(data: data)
        var items = [AppleClipboardItem]()
        var totalFlavorCount = 0
        var totalAliasCount = 0
        var metadataBytes = 0
        while !reader.isAtEnd {
            guard items.count < maximumItemCount else { throw AppleClipboardError.invalidMessage }
            let flavorCount = try Int(reader.readUInt32())
            totalFlavorCount += flavorCount
            guard totalFlavorCount <= maximumFlavorCount else {
                throw AppleClipboardError.invalidMessage
            }
            var flavors = [AppleClipboardFlavor]()
            flavors.reserveCapacity(flavorCount)
            for _ in 0..<flavorCount {
                let type = try reader.readString(metadataBytes: &metadataBytes)
                _ = try reader.readUInt32()
                let aliasCount = try Int(reader.readUInt32())
                totalAliasCount += aliasCount
                guard totalAliasCount <= maximumAliasCount,
                      !type.isEmpty || aliasCount > 0 else {
                    throw AppleClipboardError.invalidMessage
                }
                var aliases = [AppleClipboardTypeAlias]()
                aliases.reserveCapacity(aliasCount)
                for _ in 0..<aliasCount {
                    aliases.append(AppleClipboardTypeAlias(
                        tagClass: try reader.readString(metadataBytes: &metadataBytes),
                        preferredTag: try reader.readString(metadataBytes: &metadataBytes)
                    ))
                }
                flavors.append(AppleClipboardFlavor(
                    type: type,
                    aliases: aliases,
                    value: try reader.readData()
                ))
            }
            items.append(AppleClipboardItem(flavors: flavors))
        }
        return AppleClipboardArchive(items: items)
    }

    fileprivate static func validateMetadata(_ value: Data, total: inout Int) throws {
        guard value.count <= maximumMetadataLength else {
            throw AppleClipboardError.invalidMessage
        }
        total += value.count
        guard total <= maximumMetadataBytes else { throw AppleClipboardError.invalidMessage }
    }
}

struct AppleClipboardReassembler {
    private var buffer = Data()
    private var expectedLength: Int?

    var isInProgress: Bool { !buffer.isEmpty }

    mutating func process(_ fragment: Data) throws -> Data? {
        if buffer.isEmpty {
            guard let expected = try AppleClipboardMessage.expectedLength(ofFirstFragment: fragment) else {
                return nil
            }
            expectedLength = expected
        }
        buffer.append(fragment)
        guard let expectedLength, buffer.count >= expectedLength else { return nil }
        let message = buffer.prefix(expectedLength)
        buffer.removeAll(keepingCapacity: false)
        self.expectedLength = nil
        return Data(message)
    }
}

enum AppleClipboardError: LocalizedError, Equatable {
    case invalidMessage
    case payloadTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidMessage: "The remote Mac sent invalid clipboard data."
        case .payloadTooLarge: "The clipboard is too large to synchronize."
        }
    }
}

private struct ClipboardArchiveReader {
    let data: Data
    var offset = 0

    var isAtEnd: Bool { offset == data.count }

    mutating func readUInt32() throws -> UInt32 {
        guard offset <= data.count - 4 else { throw AppleClipboardError.invalidMessage }
        defer { offset += 4 }
        return try data.uint32BE(at: offset)
    }

    mutating func readData() throws -> Data {
        let length = try Int(readUInt32())
        guard length <= AppleClipboardMessage.maximumArchiveLength,
              offset <= data.count - length else { throw AppleClipboardError.invalidMessage }
        defer { offset += length }
        return data.subdata(in: offset..<(offset + length))
    }

    mutating func readString(metadataBytes: inout Int) throws -> String {
        let value = try readData()
        try AppleClipboardMessage.validateMetadata(value, total: &metadataBytes)
        guard let string = String(data: value, encoding: .utf8) else {
            throw AppleClipboardError.invalidMessage
        }
        return string
    }
}

private extension Data {
    mutating func appendClipboardData(_ value: Data) throws {
        guard value.count <= Int(UInt32.max) else { throw AppleClipboardError.payloadTooLarge }
        appendUInt32BE(UInt32(value.count))
        append(value)
    }
}
