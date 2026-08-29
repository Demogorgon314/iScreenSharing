import Foundation

public struct AppleFileTransferRequest: Equatable, Sendable {
    public let sessionID: UInt32
    public let destinationPath: String

    public init(sessionID: UInt32, destinationPath: String) {
        self.sessionID = sessionID
        self.destinationPath = destinationPath
    }
}

public struct AppleFileCopyFrame: Equatable, Sendable {
    public let command: UInt16
    public let sessionID: UInt32
    public let totalBytes: UInt64?
    public let transferredBytes: UInt64
    public let isDone: Bool
    public let status: Int32?

    public init(
        command: UInt16,
        sessionID: UInt32,
        totalBytes: UInt64?,
        transferredBytes: UInt64,
        isDone: Bool,
        status: Int32?
    ) {
        self.command = command
        self.sessionID = sessionID
        self.totalBytes = totalBytes
        self.transferredBytes = transferredBytes
        self.isDone = isDone
        self.status = status
    }
}

public enum AppleFileTransferResponse: Equatable, Sendable {
    case completed(sessionID: UInt32, errorCode: UInt16, name: String)
    case progress(sessionID: UInt32, fraction: Double)
}

public enum AppleFileTransferMessage {
    public static let maximumDropPayloadLength = 0x70_0000
    public static let maximumDestinationPathLength = 0x3ff
    public static let maximumFileCopyBodyLength = 1 * 1_024 * 1_024
    public static let maximumRecordPlaintextLength = 60_000

    public static func beginDrop(fileURL: URL, sessionID: UInt32) throws -> Data {
        guard sessionID != 0, fileURL.isFileURL else {
            throw AppleFileTransferError.invalidMessage
        }
        let value = Data(fileURL.standardizedFileURL.absoluteString.utf8)
        var archive = Data()
        archive.appendUInt32BE(1)
        try archive.appendFileTransferField(Data("public.file-url".utf8))
        archive.appendUInt32BE(0)
        archive.appendUInt32BE(1)
        try archive.appendFileTransferField(Data("com.apple.ostype".utf8))
        try archive.appendFileTransferField(Data("furl".utf8))
        try archive.appendFileTransferField(value)

        let compressed = try ZlibCodec.compressSyncFlush(
            archive,
            maximumOutputLength: maximumDropPayloadLength
        )
        guard archive.count <= Int(UInt32.max), compressed.count <= maximumDropPayloadLength else {
            throw AppleFileTransferError.payloadTooLarge
        }
        var message = Data([0x20, 0, 0, 0])
        message.appendUInt32BE(sessionID)
        message.appendUInt32BE(UInt32(archive.count))
        message.appendUInt32BE(UInt32(compressed.count))
        message.append(compressed)
        return message
    }

    public static func cancelDrop(sessionID: UInt32) throws -> Data {
        guard sessionID != 0 else { throw AppleFileTransferError.invalidMessage }
        var message = Data([0x20, 0, 0, 0])
        message.appendUInt32BE(sessionID)
        message.appendUInt32BE(0)
        message.appendUInt32BE(0)
        return message
    }

    public static func fileRequest(from message: Data) throws -> AppleFileTransferRequest {
        guard message.count >= 12, message[0] == 0x1e else {
            throw AppleFileTransferError.invalidMessage
        }
        let sessionID = try message.uint32BE(at: 4)
        let pathLength = try Int(message.uint32BE(at: 8))
        guard sessionID != 0, pathLength > 0,
              pathLength <= maximumDestinationPathLength,
              message.count == 12 + pathLength else {
            throw AppleFileTransferError.invalidMessage
        }
        let pathData = message.subdata(in: 12..<message.count)
        guard !pathData.contains(0),
              let path = String(data: pathData, encoding: .utf8),
              !path.isEmpty else {
            throw AppleFileTransferError.invalidMessage
        }
        return AppleFileTransferRequest(sessionID: sessionID, destinationPath: path)
    }

    public static func startFileReceive(sessionID: UInt32, destinationPath: String) throws -> Data {
        let path = Data(destinationPath.utf8)
        guard sessionID != 0, !path.isEmpty, !path.contains(0),
              path.count <= maximumDestinationPathLength,
              path.count <= Int(UInt16.max) else {
            throw AppleFileTransferError.invalidMessage
        }
        var body = Data()
        body.appendUInt16BE(1)
        body.appendUInt16BE(2)
        body.appendUInt32BE(sessionID)
        body.appendUInt32BE(0)
        body.appendUInt32BE(0)
        body.appendUInt16BE(UInt16(path.count))
        body.append(path)
        body.append(0)
        return fileCopyMessage(body: body)
    }

    public static func senderFrame(
        from message: Data,
        expectedSessionID: UInt32
    ) throws -> AppleFileCopyFrame {
        let envelope = try fileCopyEnvelope(from: message)
        guard envelope.sessionID == expectedSessionID else {
            throw AppleFileTransferError.sessionMismatch
        }
        let body = envelope.body
        switch envelope.command {
        case 100:
            guard body.count == 60,
                  try body.uint32BE(at: 8) == 1,
                  try body.uint64BE(at: 32) == 1,
                  try body.uint64BE(at: 48) == 0 else {
                throw AppleFileTransferError.invalidMessage
            }
            return AppleFileCopyFrame(
                command: 100,
                sessionID: envelope.sessionID,
                totalBytes: try body.uint64BE(at: 16),
                transferredBytes: 0,
                isDone: false,
                status: nil
            )
        case 101:
            guard body.count >= 113, body[8] == 1,
                  try body.uint16BE(at: 100) == 0 else {
                throw AppleFileTransferError.invalidMessage
            }
            let nameLength = try Int(body.uint16BE(at: 108))
            guard nameLength > 0, nameLength <= body.count - 113,
                  body[112 + nameLength] == 0,
                  String(data: body.subdata(in: 112..<(112 + nameLength)), encoding: .utf8) != nil else {
                throw AppleFileTransferError.invalidMessage
            }
            return AppleFileCopyFrame(
                command: 101,
                sessionID: envelope.sessionID,
                totalBytes: nil,
                transferredBytes: 0,
                isDone: false,
                status: nil
            )
        case 102:
            guard body.count >= 12 else { throw AppleFileTransferError.invalidMessage }
            let dataLength = try Int(body.uint32BE(at: 8))
            guard dataLength <= 65_536, body.count == 12 + dataLength else {
                throw AppleFileTransferError.invalidMessage
            }
            return AppleFileCopyFrame(
                command: 102,
                sessionID: envelope.sessionID,
                totalBytes: nil,
                transferredBytes: UInt64(dataLength),
                isDone: false,
                status: nil
            )
        case 103:
            guard body.count >= 18, try body.uint16BE(at: 8) == 1 else {
                throw AppleFileTransferError.invalidMessage
            }
            let uncompressedLength = try Int(body.uint32BE(at: 10))
            let compressedLength = try Int(body.uint32BE(at: 14))
            guard uncompressedLength <= 65_536,
                  compressedLength <= maximumFileCopyBodyLength,
                  body.count == 18 + compressedLength else {
                throw AppleFileTransferError.invalidMessage
            }
            return AppleFileCopyFrame(
                command: 103,
                sessionID: envelope.sessionID,
                totalBytes: nil,
                transferredBytes: UInt64(uncompressedLength),
                isDone: false,
                status: nil
            )
        case 104:
            guard body.count == 12 else { throw AppleFileTransferError.invalidMessage }
            return AppleFileCopyFrame(
                command: 104,
                sessionID: envelope.sessionID,
                totalBytes: nil,
                transferredBytes: 0,
                isDone: true,
                status: try body.int32LE(at: 8)
            )
        default:
            throw AppleFileTransferError.unsupportedCommand
        }
    }

    public static func senderItemInfo(
        from message: Data,
        expectedSessionID: UInt32
    ) throws -> AppleFileCopyFrame {
        let bodyLength = try Int(message.uint32LE(at: 2))
        guard message.count == 66,
              message[0] == 0x22,
              message[1] == 0,
              bodyLength == 60,
              try message.uint16BE(at: 6) == 1,
              try message.uint16BE(at: 8) == 100,
              try message.uint32BE(at: 10) == expectedSessionID else {
            throw AppleFileTransferError.invalidMessage
        }
        return AppleFileCopyFrame(
            command: 100,
            sessionID: expectedSessionID,
            totalBytes: try message.uint64LE(at: 22),
            transferredBytes: 0,
            isDone: false,
            status: nil
        )
    }

    public static func response(from message: Data) throws -> AppleFileTransferResponse {
        let envelope = try fileCopyEnvelope(from: message)
        switch envelope.command {
        case 200:
            let body = envelope.body
            guard body.count >= 13 else { throw AppleFileTransferError.invalidMessage }
            let errorCode = try body.uint16BE(at: 8)
            let nameLength = try Int(body.uint16BE(at: 10))
            guard body.count == 13 + nameLength,
                  body[12 + nameLength] == 0,
                  !body[12..<(12 + nameLength)].contains(0),
                  let name = String(data: body.subdata(in: 12..<(12 + nameLength)), encoding: .utf8) else {
                throw AppleFileTransferError.invalidMessage
            }
            return .completed(sessionID: envelope.sessionID, errorCode: errorCode, name: name)
        case 300:
            let body = envelope.body
            guard body.count == 16 else { throw AppleFileTransferError.invalidMessage }
            let bits = try body.uint64BE(at: 8)
            let fraction = Double(bitPattern: bits)
            return .progress(sessionID: envelope.sessionID, fraction: fraction)
        default:
            throw AppleFileTransferError.unsupportedCommand
        }
    }

    public static func fragments(of message: Data) -> [Data] {
        stride(from: 0, to: message.count, by: maximumRecordPlaintextLength).map { offset in
            message.subdata(in: offset..<min(message.count, offset + maximumRecordPlaintextLength))
        }
    }

    private static func fileCopyEnvelope(
        from message: Data
    ) throws -> (command: UInt16, sessionID: UInt32, body: Data) {
        guard message.count >= 14, message[0] == 0x22, message[1] == 0 else {
            throw AppleFileTransferError.invalidMessage
        }
        let bodyLength = try Int(message.uint32BE(at: 2))
        guard bodyLength >= 8, bodyLength <= maximumFileCopyBodyLength,
              message.count == 6 + bodyLength else {
            throw AppleFileTransferError.invalidMessage
        }
        let body = message.subdata(in: 6..<message.count)
        guard try body.uint16BE(at: 0) == 1 else {
            throw AppleFileTransferError.invalidMessage
        }
        return (
            try body.uint16BE(at: 2),
            try body.uint32BE(at: 4),
            body
        )
    }

    private static func fileCopyMessage(body: Data) -> Data {
        var message = Data([0x22, 0])
        message.appendUInt32BE(UInt32(body.count))
        message.append(body)
        return message
    }
}

public enum AppleFileCopyToolOutput: Equatable, Sendable {
    case frame(Data)
    case itemInfo(Data)
    case finished(status: UInt16)
}

public struct AppleFileCopyToolMessageParser {
    private var buffer = Data()

    public init() {}

    public mutating func process(_ bytes: Data) throws -> [AppleFileCopyToolOutput] {
        buffer.append(bytes)
        var output = [AppleFileCopyToolOutput]()
        while buffer.count >= 4 {
            let messageLength = try Int(buffer.uint32LE(at: 0))
            guard messageLength >= 2,
                  messageLength <= AppleFileTransferMessage.maximumFileCopyBodyLength + 8 else {
                throw AppleFileTransferError.invalidToolOutput
            }
            guard buffer.count >= 4 + messageLength else { break }
            let message = buffer.subdata(in: 4..<(4 + messageLength))
            buffer.removeSubrange(0..<(4 + messageLength))
            let command = try message.uint16LE(at: 0)
            let payload = message.dropFirst(2)
            switch command {
            case 1:
                output.append(.frame(Data(payload)))
            case 2:
                guard payload.count == 2 else { throw AppleFileTransferError.invalidToolOutput }
                output.append(.finished(status: try Data(payload).uint16LE(at: 0)))
            case 3:
                output.append(.itemInfo(Data(payload)))
            default:
                throw AppleFileTransferError.invalidToolOutput
            }
        }
        return output
    }

    public mutating func finish() throws {
        guard buffer.isEmpty else { throw AppleFileTransferError.invalidToolOutput }
    }
}

public enum AppleFileTransferError: LocalizedError, Equatable {
    case unavailable
    case invalidMessage
    case payloadTooLarge
    case sessionMismatch
    case unsupportedCommand
    case invalidToolOutput
    case transferAlreadyInProgress
    case requestExpired
    case unsupportedItem
    case senderFailed
    case remoteRejected
    case closed

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "File transfer is unavailable on this version of macOS."
        case .invalidMessage, .invalidToolOutput:
            "The file transfer protocol returned invalid data."
        case .payloadTooLarge:
            "The file transfer request is too large."
        case .sessionMismatch:
            "The remote Mac returned a mismatched file transfer session."
        case .unsupportedCommand:
            "The remote Mac returned an unsupported file transfer command."
        case .transferAlreadyInProgress:
            "Another file transfer is already in progress."
        case .requestExpired:
            "The remote Mac did not accept the file drop in time."
        case .unsupportedItem:
            "Only one regular file can be transferred at a time."
        case .senderFailed:
            "The file could not be read for transfer."
        case .remoteRejected:
            "The remote Mac could not receive the file."
        case .closed:
            "The Screen Sharing session is closed."
        }
    }
}

private extension Data {
    mutating func appendUInt16BE(_ value: UInt16) {
        BigEndianWire.append(value, to: &self)
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        BigEndianWire.append(value, to: &self)
    }

    func uint16BE(at offset: Int) throws -> UInt16 {
        guard let value = BigEndianWire.uint16(from: self, at: offset) else {
            throw FileTransferWireError.outOfBounds
        }
        return value
    }

    func uint32BE(at offset: Int) throws -> UInt32 {
        guard let value = BigEndianWire.uint32(from: self, at: offset) else {
            throw FileTransferWireError.outOfBounds
        }
        return value
    }

    mutating func appendFileTransferField(_ value: Data) throws {
        guard value.count <= Int(UInt32.max) else { throw AppleFileTransferError.payloadTooLarge }
        appendUInt32BE(UInt32(value.count))
        append(value)
    }

    func uint16LE(at offset: Int) throws -> UInt16 {
        guard offset >= 0, count >= offset + 2 else { throw FileTransferWireError.outOfBounds }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func uint32LE(at offset: Int) throws -> UInt32 {
        guard offset >= 0, count >= offset + 4 else { throw FileTransferWireError.outOfBounds }
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    func uint64LE(at offset: Int) throws -> UInt64 {
        UInt64(try uint32LE(at: offset)) | UInt64(try uint32LE(at: offset + 4)) << 32
    }

    func int32LE(at offset: Int) throws -> Int32 {
        Int32(bitPattern: try uint32LE(at: offset))
    }

    func uint64BE(at offset: Int) throws -> UInt64 {
        UInt64(try uint32BE(at: offset)) << 32 | UInt64(try uint32BE(at: offset + 4))
    }
}

private enum FileTransferWireError: Error {
    case outOfBounds
}
