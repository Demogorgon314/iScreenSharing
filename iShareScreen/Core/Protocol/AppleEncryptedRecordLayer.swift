import CryptoKit
import Foundation

final class AppleEncryptedRecordLayer: @unchecked Sendable {
    private static let blockSize = 16
    private static let authenticationCodeLength = 20
    private static let receiveCounterWindow: UInt32 = 6

    let contentKey: Data

    private let lock = NSLock()
    private var encryptionIV: Data
    private var decryptionIV: Data
    private var sendCounter: UInt32 = 0
    private var receiveCounter: UInt32 = 0

    init(keys: AppleRecordKeys) {
        contentKey = keys.key
        encryptionIV = keys.initializationVector
        decryptionIV = keys.initializationVector
    }

    func encrypt(_ message: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        let paddingLength = (
            Self.blockSize
                - ((2 + message.count + Self.authenticationCodeLength) % Self.blockSize)
        ) % Self.blockSize
        var authenticatedBody = Data()
        guard message.count <= Int(UInt16.max) else {
            throw AppleEncryptedRecordError.messageTooLarge
        }
        authenticatedBody.appendUInt16BE(UInt16(message.count))
        authenticatedBody.append(message)
        authenticatedBody.append(Data(repeating: 0, count: paddingLength))

        var digestInput = Data()
        digestInput.appendUInt32BE(sendCounter)
        digestInput.append(authenticatedBody)
        authenticatedBody.append(Data(Insecure.SHA1.hash(data: digestInput)))

        let ciphertext = try Cryptography.encryptAESCBC(
            authenticatedBody,
            key: contentKey,
            iv: encryptionIV
        )
        guard ciphertext.count <= Int(UInt16.max),
              let nextIV = ciphertext.suffix(Self.blockSize).data else {
            throw AppleEncryptedRecordError.messageTooLarge
        }
        encryptionIV = nextIV
        sendCounter &+= 1

        var record = Data()
        record.appendUInt16BE(UInt16(ciphertext.count))
        record.append(ciphertext)
        return record
    }

    func decrypt(_ ciphertext: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }

        guard ciphertext.count > Self.authenticationCodeLength,
              ciphertext.count.isMultiple(of: Self.blockSize),
              let nextIV = ciphertext.suffix(Self.blockSize).data else {
            throw AppleEncryptedRecordError.invalidCiphertext
        }
        let plaintext = try Cryptography.decryptAESCBC(
            ciphertext,
            key: contentKey,
            iv: decryptionIV
        )
        decryptionIV = nextIV

        let bodyEnd = plaintext.count - Self.authenticationCodeLength
        let body = plaintext.prefix(bodyEnd)
        let receivedDigest = plaintext.suffix(Self.authenticationCodeLength)
        let startCounter = receiveCounter
        receiveCounter &+= 1

        for candidate in candidateCounters(around: startCounter) {
            var digestInput = Data()
            digestInput.appendUInt32BE(candidate)
            digestInput.append(body)
            let expectedDigest = Data(Insecure.SHA1.hash(data: digestInput))
            guard constantTimeEqual(expectedDigest, Data(receivedDigest)) else { continue }

            receiveCounter = candidate &+ 1
            let bodyData = Data(body)
            let messageLength = try Int(bodyData.uint16BE(at: 0))
            guard messageLength <= bodyData.count - 2 else {
                throw AppleEncryptedRecordError.invalidPlaintext
            }
            return bodyData.subdata(in: 2..<(2 + messageLength))
        }
        throw AppleEncryptedRecordError.authenticationFailed
    }

    func decryptAvailableRecords(in buffer: inout Data) throws -> [Data] {
        var messages = [Data]()
        var consumed = 0
        while buffer.count - consumed >= 2 {
            let length = try Int(buffer.uint16BE(at: consumed))
            guard length > 0, length.isMultiple(of: Self.blockSize) else {
                throw AppleEncryptedRecordError.invalidCiphertext
            }
            guard buffer.count - consumed >= 2 + length else { break }
            let start = consumed + 2
            messages.append(try decrypt(buffer.subdata(in: start..<(start + length))))
            consumed += 2 + length
        }
        if consumed > 0 {
            buffer.removeSubrange(0..<consumed)
        }
        return messages
    }

    private func candidateCounters(around counter: UInt32) -> [UInt32] {
        let lower = counter == 0 ? 0 : counter - 1
        let upper = counter.addingReportingOverflow(Self.receiveCounterWindow - 1)
        let upperValue = upper.overflow ? UInt32.max : upper.partialValue
        return Array(lower...upperValue)
    }

    private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

private extension Data.SubSequence {
    var data: Data? {
        isEmpty ? nil : Data(self)
    }
}

enum AppleEncryptedRecordError: LocalizedError, Equatable {
    case messageTooLarge
    case invalidCiphertext
    case invalidPlaintext
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .messageTooLarge:
            "The encrypted Screen Sharing message is too large."
        case .invalidCiphertext, .invalidPlaintext:
            "The Mac returned an invalid encrypted message."
        case .authenticationFailed:
            "The encrypted Screen Sharing message failed authentication."
        }
    }
}

