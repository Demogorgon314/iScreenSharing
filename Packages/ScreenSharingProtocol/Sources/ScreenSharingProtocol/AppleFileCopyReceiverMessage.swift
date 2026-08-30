import Foundation

public enum AppleFileCopyReceiverPayload: Equatable, Sendable {
    case summary(AppleFileCopySummary)
    case item(AppleFileCopyItemMetadata)
    case data(Data)
    case compressedData(uncompressedLength: Int, data: Data)
    case done(status: Int32)
}

public struct AppleFileCopyReceiverFrame: Equatable, Sendable {
    public let sessionID: UInt32
    public let payload: AppleFileCopyReceiverPayload

    public init(sessionID: UInt32, payload: AppleFileCopyReceiverPayload) {
        self.sessionID = sessionID
        self.payload = payload
    }
}

public struct AppleRemoteFileDrag: Equatable, Sendable {
    public let sessionID: UInt32
    public let sourcePaths: [String]
    public let imagePNG: Data?

    public init(sessionID: UInt32, sourcePaths: [String], imagePNG: Data?) {
        self.sessionID = sessionID
        self.sourcePaths = sourcePaths
        self.imagePNG = imagePNG
    }
}

public extension AppleFileTransferMessage {
    static let maximumRemoteDragPayloadLength = 0x63ff_fff

    static func expectedStreamMessageLength(from fragment: Data) throws -> Int? {
        guard let type = fragment.first else { return nil }
        switch type {
        case 0x1e:
            guard fragment.count >= 12 else { return nil }
            let pathLength = try Int(fragment.fileCopyUInt32BE(at: 8))
            guard pathLength <= maximumDestinationPathLength else {
                throw AppleFileTransferError.payloadTooLarge
            }
            return 12 + pathLength
        case 0x20:
            guard fragment.count >= 16 else { return nil }
            let uncompressedLength = try Int(fragment.fileCopyUInt32BE(at: 8))
            let transmittedLength = try Int(fragment.fileCopyUInt32BE(at: 12))
            guard uncompressedLength <= maximumRemoteDragPayloadLength,
                  transmittedLength <= maximumRemoteDragPayloadLength else {
                throw AppleFileTransferError.payloadTooLarge
            }
            return 16 + transmittedLength
        case 0x22:
            guard fragment.count >= 6 else { return nil }
            let bodyLength = try Int(fragment.fileCopyUInt32BE(at: 2))
            guard bodyLength >= 8, bodyLength <= maximumFileCopyBodyLength else {
                throw AppleFileTransferError.payloadTooLarge
            }
            return 6 + bodyLength
        default:
            return nil
        }
    }

    static func remoteDrag(from message: Data) throws -> AppleRemoteFileDrag? {
        guard message.count >= 16, message[0] == 0x20 else {
            throw AppleFileTransferError.invalidMessage
        }
        let sessionID = try message.fileCopyUInt32BE(at: 4)
        let uncompressedLength = try Int(message.fileCopyUInt32BE(at: 8))
        let transmittedLength = try Int(message.fileCopyUInt32BE(at: 12))
        guard uncompressedLength <= maximumRemoteDragPayloadLength,
              transmittedLength <= maximumRemoteDragPayloadLength,
              message.count == 16 + transmittedLength else {
            throw AppleFileTransferError.payloadTooLarge
        }
        guard sessionID != 0 else { return nil }
        guard uncompressedLength != 0 || transmittedLength != 0 else { return nil }
        guard uncompressedLength > 0, transmittedLength > 0 else {
            throw AppleFileTransferError.invalidMessage
        }
        let packed = try ZlibCodec.decompressSyncFlush(
            message.subdata(in: 16..<message.count),
            expectedSize: uncompressedLength,
            maximumOutputLength: maximumRemoteDragPayloadLength
        )
        guard packed.count == uncompressedLength else {
            throw AppleFileTransferError.invalidMessage
        }
        let archive = try AppleClipboardMessage.unpackedArchive(from: packed)
        var sourcePaths = [String]()
        var imagePNG: Data?
        for item in archive.items {
            for flavor in item.flavors {
                if imagePNG == nil,
                   flavor.type == "com.apple.remotedesktop.dragimage-png" {
                    imagePNG = flavor.value
                }
                let isFileURL = flavor.type == "public.file-url"
                    || flavor.aliases.contains {
                        $0.tagClass == "com.apple.ostype" && $0.preferredTag == "furl"
                    }
                guard isFileURL,
                      let value = String(data: flavor.value, encoding: .utf8),
                      let url = URL(string: value),
                      url.isFileURL,
                      !url.path.isEmpty else { continue }
                sourcePaths.append(url.path)
            }
        }
        guard !sourcePaths.isEmpty else { throw AppleFileTransferError.invalidMessage }
        return AppleRemoteFileDrag(
            sessionID: sessionID,
            sourcePaths: sourcePaths,
            imagePNG: imagePNG
        )
    }

    static func receiverFrame(from message: Data) throws -> AppleFileCopyReceiverFrame {
        let envelope = try ReceiverEnvelope(message: message)
        let payload: AppleFileCopyReceiverPayload
        switch envelope.command {
        case 100:
            payload = .summary(try receiverSummary(from: envelope.body))
        case 101:
            payload = .item(try receiverItem(from: envelope.body))
        case 102:
            guard envelope.body.count >= 12 else {
                throw AppleFileTransferError.invalidMessage
            }
            let count = try Int(envelope.body.fileCopyUInt32BE(at: 8))
            guard (1...65_536).contains(count), envelope.body.count == 12 + count else {
                throw AppleFileTransferError.invalidMessage
            }
            payload = .data(envelope.body.subdata(in: 12..<envelope.body.count))
        case 103:
            guard envelope.body.count >= 18,
                  try envelope.body.fileCopyUInt16BE(at: 8) == 1 else {
                throw AppleFileTransferError.invalidMessage
            }
            let uncompressedLength = try Int(envelope.body.fileCopyUInt32BE(at: 10))
            let compressedLength = try Int(envelope.body.fileCopyUInt32BE(at: 14))
            let maximumCompressedLength = uncompressedLength
                + uncompressedLength / 16_384
                + 10_038
            guard (1...65_536).contains(uncompressedLength), compressedLength > 0,
                  compressedLength <= maximumCompressedLength,
                  envelope.body.count == 18 + compressedLength else {
                throw AppleFileTransferError.invalidMessage
            }
            payload = .compressedData(
                uncompressedLength: uncompressedLength,
                data: envelope.body.subdata(in: 18..<envelope.body.count)
            )
        case 104:
            guard envelope.body.count == 12 else {
                throw AppleFileTransferError.invalidMessage
            }
            payload = .done(status: try envelope.body.fileCopyInt32LE(at: 8))
        default:
            throw AppleFileTransferError.unsupportedCommand
        }
        return AppleFileCopyReceiverFrame(sessionID: envelope.sessionID, payload: payload)
    }

    private static func receiverSummary(from body: Data) throws -> AppleFileCopySummary {
        guard body.count == 60 else { throw AppleFileTransferError.invalidMessage }
        let rootFlag = try body.fileCopyUInt32BE(at: 8)
        let fileCount = try body.fileCopyUInt64BE(at: 32)
        let forkCount = try body.fileCopyUInt64BE(at: 40)
        let folderCount = try body.fileCopyUInt64BE(at: 48)
        guard rootFlag <= 1,
              try body.fileCopyUInt32BE(at: 12) == 0,
              forkCount == 0,
              try body.fileCopyUInt32BE(at: 56) == 0,
              rootFlag == 0 ? folderCount > 0 : (fileCount == 1 && folderCount == 0) else {
            throw AppleFileTransferError.invalidMessage
        }
        return AppleFileCopySummary(
            rootIsFile: rootFlag == 1,
            logicalBytes: try body.fileCopyUInt64BE(at: 16),
            physicalBytes: try body.fileCopyUInt64BE(at: 24),
            fileCount: fileCount,
            folderCount: folderCount
        )
    }

    private static func receiverItem(from body: Data) throws -> AppleFileCopyItemMetadata {
        guard body.count >= 113,
              let type = AppleFileCopyItemType(rawValue: body[8]) else {
            throw AppleFileTransferError.invalidMessage
        }
        let nameLength = try Int(body.fileCopyUInt16BE(at: 108))
        let linkLengthMinusOne = try body.fileCopyUInt16BE(at: 110)
        guard nameLength > 0, nameLength <= body.count - 113 else {
            throw AppleFileTransferError.invalidMessage
        }
        let nameEnd = 112 + nameLength
        guard body[nameEnd] == 0,
              !body[112..<nameEnd].contains(0),
              let name = String(data: body.subdata(in: 112..<nameEnd), encoding: .utf8),
              !name.isEmpty else {
            throw AppleFileTransferError.invalidMessage
        }
        let dataForkSize = try body.fileCopyUInt64BE(at: 50)
        let trailingOffset = nameEnd + 1
        let symbolicLinkTarget: Data?
        let extendedAttributes: [AppleFileCopyExtendedAttribute]
        if type == .symbolicLink {
            guard dataForkSize > 0, dataForkSize <= UInt64(UInt16.max) + 1,
                  linkLengthMinusOne == UInt16(dataForkSize - 1),
                  trailingOffset + Int(dataForkSize) == body.count else {
                throw AppleFileTransferError.invalidMessage
            }
            symbolicLinkTarget = body.subdata(
                in: trailingOffset..<(trailingOffset + Int(dataForkSize))
            )
            extendedAttributes = []
        } else {
            guard linkLengthMinusOne == 0 else {
                throw AppleFileTransferError.invalidMessage
            }
            symbolicLinkTarget = nil
            extendedAttributes = try receiverExtendedAttributes(
                from: body.subdata(in: trailingOffset..<body.count)
            )
        }
        var finderInfo = body.subdata(in: 10..<42)
        finderInfo[24] = 0
        finderInfo[25] = 0
        return AppleFileCopyItemMetadata(
            type: type,
            userAccess: body[9],
            finderInfo: finderInfo,
            resourceForkSize: try body.fileCopyUInt64BE(at: 42),
            dataForkSize: dataForkSize,
            creationDate: try receiverDate(from: body, at: 58),
            contentModificationDate: try receiverDate(from: body, at: 66),
            attributeModificationDate: try receiverDate(from: body, at: 74),
            accessDate: try receiverDate(from: body, at: 82),
            backupDate: try receiverDate(from: body, at: 90),
            nodeFlags: try body.fileCopyUInt16BE(at: 98),
            level: try body.fileCopyUInt16BE(at: 100),
            mode: try body.fileCopyUInt16BE(at: 102),
            textEncodingHint: try body.fileCopyUInt32BE(at: 104),
            name: name,
            symbolicLinkTarget: symbolicLinkTarget,
            extendedAttributes: extendedAttributes
        )
    }

    private static func receiverDate(from body: Data, at offset: Int) throws -> AppleFileCopyUTCDateTime {
        let seconds = UInt64(try body.fileCopyUInt16BE(at: offset)) << 32
            | UInt64(try body.fileCopyUInt32BE(at: offset + 2))
        return AppleFileCopyUTCDateTime(
            seconds: seconds,
            fraction: try body.fileCopyUInt16BE(at: offset + 6)
        )
    }

    private static func receiverExtendedAttributes(
        from record: Data
    ) throws -> [AppleFileCopyExtendedAttribute] {
        guard !record.isEmpty else { return [] }
        guard record.count >= 18,
              record.prefix(4) == Data("ext1".utf8) else {
            throw AppleFileTransferError.invalidMessage
        }
        let recordLength = try Int(record.fileCopyUInt16BE(at: 8))
        guard recordLength >= 18, recordLength <= record.count else {
            throw AppleFileTransferError.invalidMessage
        }
        let blobLength = try Int(record.fileCopyUInt32BE(at: 10))
        let count = try Int(record.fileCopyUInt32BE(at: 14))
        guard count <= 50_000,
              blobLength >= 8,
              blobLength <= recordLength - 10,
              count <= (blobLength - 8) / 8 else {
            throw AppleFileTransferError.invalidMessage
        }
        var headers = [(nameLength: Int, valueLength: Int)]()
        headers.reserveCapacity(count)
        var headerOffset = 18
        for _ in 0..<count {
            let nameLength = try Int(record.fileCopyUInt32BE(at: headerOffset))
            let valueLength = try Int(record.fileCopyUInt32BE(at: headerOffset + 4))
            guard nameLength > 0 else { throw AppleFileTransferError.invalidMessage }
            headers.append((nameLength, valueLength))
            headerOffset += 8
        }
        let blobEnd = 10 + blobLength
        var dataOffset = headerOffset
        var attributes = [AppleFileCopyExtendedAttribute]()
        attributes.reserveCapacity(count)
        for header in headers {
            guard header.nameLength <= blobEnd - dataOffset else {
                throw AppleFileTransferError.invalidMessage
            }
            let nameEnd = dataOffset + header.nameLength
            guard record[nameEnd - 1] == 0,
                  let name = String(
                    data: record.subdata(in: dataOffset..<(nameEnd - 1)),
                    encoding: .utf8
                  ),
                  !name.isEmpty,
                  header.valueLength <= blobEnd - nameEnd else {
                throw AppleFileTransferError.invalidMessage
            }
            let valueEnd = nameEnd + header.valueLength
            attributes.append(AppleFileCopyExtendedAttribute(
                name: name,
                value: record.subdata(in: nameEnd..<valueEnd)
            ))
            dataOffset = valueEnd
        }
        guard dataOffset <= blobEnd else { throw AppleFileTransferError.invalidMessage }
        return attributes
    }
}

private struct ReceiverEnvelope {
    let command: UInt16
    let sessionID: UInt32
    let body: Data

    init(message: Data) throws {
        guard message.count >= 14, message[0] == 0x22, message[1] == 0 else {
            throw AppleFileTransferError.invalidMessage
        }
        let bodyLength = try Int(message.fileCopyUInt32BE(at: 2))
        guard bodyLength >= 8,
              bodyLength <= AppleFileTransferMessage.maximumFileCopyBodyLength,
              message.count == 6 + bodyLength else {
            throw AppleFileTransferError.invalidMessage
        }
        body = message.subdata(in: 6..<message.count)
        guard try body.fileCopyUInt16BE(at: 0) == 1 else {
            throw AppleFileTransferError.invalidMessage
        }
        command = try body.fileCopyUInt16BE(at: 2)
        sessionID = try body.fileCopyUInt32BE(at: 4)
        guard sessionID != 0 else { throw AppleFileTransferError.invalidMessage }
    }
}

private extension Data {
    func fileCopyUInt16BE(at offset: Int) throws -> UInt16 {
        guard let value = BigEndianWire.uint16(from: self, at: offset) else {
            throw AppleFileTransferError.invalidMessage
        }
        return value
    }

    func fileCopyUInt32BE(at offset: Int) throws -> UInt32 {
        guard let value = BigEndianWire.uint32(from: self, at: offset) else {
            throw AppleFileTransferError.invalidMessage
        }
        return value
    }

    func fileCopyUInt64BE(at offset: Int) throws -> UInt64 {
        UInt64(try fileCopyUInt32BE(at: offset)) << 32
            | UInt64(try fileCopyUInt32BE(at: offset + 4))
    }

    func fileCopyInt32LE(at offset: Int) throws -> Int32 {
        guard offset >= 0, count >= offset + 4 else {
            throw AppleFileTransferError.invalidMessage
        }
        let value = UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
        return Int32(bitPattern: value)
    }
}
