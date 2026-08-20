import Foundation

enum AppleClipboardMessage {
    static let maximumPayloadLength = 16 * 1_024 * 1_024
    static let textType = "public.utf8-plain-text"

    static let enable = Data([0x15, 0x00, 0x00, 0x01, 0, 0, 0, 0])
    static let fetch = Data([0x0b, 0x00, 0, 0, 0, 0, 0, 0])

    static func send(text: String) throws -> Data {
        let textData = Data(text.utf8)
        let typeData = Data(textType.utf8)
        guard textData.count <= maximumPayloadLength else { throw AppleClipboardError.payloadTooLarge }

        var archive = Data()
        archive.appendUInt32BE(1)
        archive.appendUInt32BE(UInt32(typeData.count))
        archive.append(typeData)
        archive.appendUInt32BE(0)
        archive.appendUInt32BE(0)
        archive.appendUInt32BE(UInt32(textData.count))
        archive.append(textData)
        let compressed = try ZlibCodec.compress(archive)

        var message = Data([0x1f, 0, 0, 0])
        message.appendUInt32BE(0)
        message.appendUInt32BE(UInt32(archive.count))
        message.appendUInt32BE(UInt32(compressed.count))
        message.append(compressed)
        return message
    }

    static func text(from message: Data) throws -> String? {
        guard message.count >= 16, message[0] == 0x1f else {
            throw AppleClipboardError.invalidMessage
        }
        let uncompressedSize = try Int(message.uint32BE(at: 8))
        let compressedSize = try Int(message.uint32BE(at: 12))
        guard uncompressedSize <= maximumPayloadLength,
              compressedSize <= maximumPayloadLength,
              message.count >= 16 + compressedSize else {
            throw AppleClipboardError.payloadTooLarge
        }
        let payload = message.subdata(in: 16..<(16 + compressedSize))
        let archive = try ZlibCodec.decompressSyncFlush(payload, expectedSize: uncompressedSize)
        guard archive.count == uncompressedSize else { throw AppleClipboardError.invalidMessage }
        return try text(fromArchive: archive)
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

    private static func text(fromArchive archive: Data) throws -> String? {
        guard archive.count >= 4 else { return nil }
        var reader = ClipboardArchiveReader(data: archive)
        let itemCount = try reader.readUInt32()
        guard itemCount <= 1_024 else { throw AppleClipboardError.invalidMessage }
        var fallback: String?
        for _ in 0..<itemCount {
            let type = try reader.readString()
            _ = try reader.readUInt32()
            let aliasCount = try reader.readUInt32()
            guard aliasCount <= 1_024 else { throw AppleClipboardError.invalidMessage }
            for _ in 0..<aliasCount {
                _ = try reader.readData()
                _ = try reader.readData()
            }
            let value = try reader.readData()
            if type == textType { return String(decoding: value, as: UTF8.self) }
            if type.hasPrefix("public."), type.contains("text") {
                fallback = String(decoding: value, as: UTF8.self)
            }
        }
        return fallback
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

    mutating func readUInt32() throws -> UInt32 {
        defer { offset += 4 }
        return try data.uint32BE(at: offset)
    }

    mutating func readData() throws -> Data {
        let length = try Int(readUInt32())
        guard length <= AppleClipboardMessage.maximumPayloadLength,
              offset <= data.count - length else { throw AppleClipboardError.invalidMessage }
        defer { offset += length }
        return data.subdata(in: offset..<(offset + length))
    }

    mutating func readString() throws -> String {
        String(decoding: try readData(), as: UTF8.self)
    }
}
