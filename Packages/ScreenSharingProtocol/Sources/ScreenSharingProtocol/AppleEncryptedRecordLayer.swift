import CryptoKit
import Foundation

public struct AppleRecordKeys: Equatable, Sendable {
    let key: Data
    let initializationVector: Data

    public init(key: Data, initializationVector: Data) throws {
        guard key.count == 16, initializationVector.count == 16 else {
            throw AppleRecordKeyError.invalidLength
        }
        self.key = key
        self.initializationVector = initializationVector
    }
}

public enum AppleRecordKeyError: LocalizedError, Equatable {
    case invalidLength
    case decryptionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidLength:
            "The Mac returned invalid encryption key material."
        case .decryptionFailed:
            "The Mac returned encryption key material that could not be decrypted."
        }
    }
}

public extension AppleRekey {
    func unwrap(using key: Data) throws -> AppleRecordKeys {
        do {
            return try AppleRecordKeys(
                key: AppleProtocolAES.decryptECB(encryptedKey, key: key),
                initializationVector: AppleProtocolAES.decryptECB(encryptedIV, key: key)
            )
        } catch let error as AppleRecordKeyError {
            throw error
        } catch {
            throw AppleRecordKeyError.decryptionFailed
        }
    }
}

public final class AppleEncryptedRecordLayer: @unchecked Sendable {
    private static let blockSize = 16
    private static let authenticationCodeLength = 20
    private static let receiveCounterWindow: UInt32 = 6

    public let contentKey: Data

    private let lock = NSLock()
    private var encryptionIV: Data
    private var decryptionIV: Data
    private var sendCounter: UInt32
    private var receiveCounter: UInt32

    public convenience init(keys: AppleRecordKeys) {
        self.init(keys: keys, sendCounter: 0, receiveCounter: 0)
    }

    init(
        keys: AppleRecordKeys,
        sendCounter: UInt32,
        receiveCounter: UInt32
    ) {
        contentKey = keys.key
        encryptionIV = keys.initializationVector
        decryptionIV = keys.initializationVector
        self.sendCounter = sendCounter
        self.receiveCounter = receiveCounter
    }

    public func encrypt(_ message: Data) throws -> Data {
        try encrypt([message])
    }

    public func encrypt(_ messages: [Data]) throws -> Data {
        try lock.withLock {
            let initialIV = encryptionIV
            let initialCounter = sendCounter
            do {
                return try messages.reduce(into: Data()) { records, message in
                    records.append(try encryptRecord(message))
                }
            } catch {
                encryptionIV = initialIV
                sendCounter = initialCounter
                throw error
            }
        }
    }

    public func decrypt(_ ciphertext: Data) throws -> Data {
        try lock.withLock {
            guard ciphertext.count > Self.authenticationCodeLength,
                  ciphertext.count.isMultiple(of: Self.blockSize) else {
                throw AppleEncryptedRecordError.invalidCiphertext
            }
            let nextIV = Data(ciphertext.suffix(Self.blockSize))
            let plaintext: Data
            do {
                plaintext = try AppleProtocolAES.decryptCBC(
                    ciphertext,
                    key: contentKey,
                    initializationVector: decryptionIV
                )
            } catch {
                throw AppleEncryptedRecordError.invalidCiphertext
            }
            decryptionIV = nextIV

            let bodyEnd = plaintext.count - Self.authenticationCodeLength
            let body = plaintext.prefix(bodyEnd)
            let receivedDigest = plaintext.suffix(Self.authenticationCodeLength)
            let startCounter = receiveCounter
            receiveCounter &+= 1

            for candidate in candidateCounters(around: startCounter) {
                var digestInput = Data()
                BigEndianWire.append(candidate, to: &digestInput)
                digestInput.append(body)
                let expectedDigest = Data(Insecure.SHA1.hash(data: digestInput))
                guard constantTimeEqual(expectedDigest, receivedDigest) else { continue }

                receiveCounter = candidate &+ 1
                let bodyData = Data(body)
                guard bodyData.count >= 2 else {
                    throw AppleEncryptedRecordError.invalidPlaintext
                }
                let messageLength = Int(bodyData[0]) << 8 | Int(bodyData[1])
                guard messageLength <= bodyData.count - 2 else {
                    throw AppleEncryptedRecordError.invalidPlaintext
                }
                return bodyData.subdata(in: 2..<(2 + messageLength))
            }
            throw AppleEncryptedRecordError.authenticationFailed
        }
    }

    private func encryptRecord(_ message: Data) throws -> Data {
        guard message.count <= Int(UInt16.max) else {
            throw AppleEncryptedRecordError.messageTooLarge
        }
        let paddingLength = (
            Self.blockSize
                - ((2 + message.count + Self.authenticationCodeLength) % Self.blockSize)
        ) % Self.blockSize
        var authenticatedBody = Data()
        BigEndianWire.append(UInt16(message.count), to: &authenticatedBody)
        authenticatedBody.append(message)
        authenticatedBody.append(Data(repeating: 0, count: paddingLength))

        var digestInput = Data()
        BigEndianWire.append(sendCounter, to: &digestInput)
        digestInput.append(authenticatedBody)
        authenticatedBody.append(Data(Insecure.SHA1.hash(data: digestInput)))

        let ciphertext: Data
        do {
            ciphertext = try AppleProtocolAES.encryptCBC(
                authenticatedBody,
                key: contentKey,
                initializationVector: encryptionIV
            )
        } catch {
            throw AppleEncryptedRecordError.encryptionFailed
        }
        guard ciphertext.count <= Int(UInt16.max) else {
            throw AppleEncryptedRecordError.messageTooLarge
        }
        encryptionIV = Data(ciphertext.suffix(Self.blockSize))
        sendCounter &+= 1

        var record = Data()
        BigEndianWire.append(UInt16(ciphertext.count), to: &record)
        record.append(ciphertext)
        return record
    }

    private func candidateCounters(around counter: UInt32) -> ClosedRange<UInt32> {
        let lower = counter == 0 ? 0 : counter - 1
        let upper = counter.addingReportingOverflow(Self.receiveCounterWindow - 1)
        return lower...(upper.overflow ? UInt32.max : upper.partialValue)
    }

    private func constantTimeEqual<C: Collection>(_ lhs: Data, _ rhs: C) -> Bool
    where C.Element == UInt8 {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

public enum AppleEncryptedRecordError: LocalizedError, Equatable {
    case messageTooLarge
    case invalidCiphertext
    case invalidPlaintext
    case authenticationFailed
    case encryptionFailed

    public var errorDescription: String? {
        switch self {
        case .messageTooLarge:
            "The encrypted Screen Sharing message is too large."
        case .invalidCiphertext, .invalidPlaintext:
            "The Mac returned an invalid encrypted message."
        case .authenticationFailed:
            "The encrypted Screen Sharing message failed authentication."
        case .encryptionFailed:
            "The encrypted Screen Sharing message could not be encrypted."
        }
    }
}
