import CryptoKit
import Foundation
import struct ScreenSharingProtocol.AppleMediaKeys

struct AppleRTPFramePacketInfo: Equatable, Sendable {
    let totalPacketsPerFrame: UInt16
    let frameSequenceNumber: UInt16
}

struct AppleRTPPacket: Equatable, Sendable {
    let header: Data
    let payload: Data
    let sequenceNumber: UInt16
    let timestamp: UInt32
    let synchronizationSource: UInt32
    let payloadType: UInt8
    let marker: Bool

    /// Apple inlines MCI Info ID 4 in the high nibble of the second extension
    /// header byte. Bit zero of that value requests acknowledgement of an LTR.
    var isLongTermReferenceFrame: Bool {
        guard let mediaControlExtension else { return false }
        return mediaControlExtension.controlByte & 0x10 != 0
    }

    /// Apple MCI Info ID 6 carries the sender-declared packet count for this
    /// encoded frame. Info ID 4 is inline, so the Info ID 6 value is the first
    /// four-byte word after the Apple RTP extension header.
    var framePacketInfo: AppleRTPFramePacketInfo? {
        guard let mediaControlExtension,
              mediaControlExtension.controlByte & 0x01 != 0 else { return nil }
        let infoOffset = mediaControlExtension.infoOffset
        guard infoOffset + 4 <= mediaControlExtension.endOffset,
              let totalPacketsPerFrame = try? header.uint16BE(at: infoOffset),
              let frameSequenceNumber = try? header.uint16BE(at: infoOffset + 2) else {
            return nil
        }
        return AppleRTPFramePacketInfo(
            totalPacketsPerFrame: totalPacketsPerFrame,
            frameSequenceNumber: frameSequenceNumber
        )
    }

    private var mediaControlExtension: (
        controlByte: UInt8,
        infoOffset: Int,
        endOffset: Int
    )? {
        guard header.count >= 12, header[0] & 0x10 != 0 else { return nil }
        let extensionOffset = 12 + Int(header[0] & 0x0f) * 4
        guard extensionOffset + 4 <= header.count,
              header[extensionOffset] >> 6 == 2,
              let wordCount = try? Int(header.uint16BE(at: extensionOffset + 2)) else {
            return nil
        }
        let endOffset = extensionOffset + 4 + wordCount * 4
        guard endOffset <= header.count else { return nil }
        return (
            controlByte: header[extensionOffset + 1],
            infoOffset: extensionOffset + 4,
            endOffset: endOffset
        )
    }
}

struct AppleSRTPKeySchedule: Equatable, Sendable {
    let cipherKey: Data
    let authenticationKey: Data
    let salt: Data

    init(masterKey: Data, masterSalt: Data) throws {
        guard masterKey.count == 32, masterSalt.count == 14 else {
            throw AppleSRTPError.invalidKeyBlob
        }
        cipherKey = try AppleMediaKeyDerivation.derive(
            masterKey: masterKey, masterSalt: masterSalt, label: 0, count: 32
        )
        authenticationKey = try AppleMediaKeyDerivation.derive(
            masterKey: masterKey, masterSalt: masterSalt, label: 1, count: 20
        )
        salt = try AppleMediaKeyDerivation.derive(
            masterKey: masterKey, masterSalt: masterSalt, label: 2, count: 14
        )
    }

    init(blob: Data) throws {
        guard blob.count == AppleMediaKeys.blobLength else { throw AppleSRTPError.invalidKeyBlob }
        try self.init(masterKey: blob.prefix(32), masterSalt: blob.suffix(14))
    }
}

private enum AppleMediaKeyDerivation {
    static func derive(
        masterKey: Data,
        masterSalt: Data,
        label: UInt8,
        count: Int
    ) throws -> Data {
        var initializationVector = Data(repeating: 0, count: 16)
        initializationVector.replaceSubrange(0..<14, with: masterSalt)
        initializationVector[7] ^= label
        var output = Data()
        var block = initializationVector
        while output.count < count {
            output.append(try Cryptography.encryptAESECB(block, key: masterKey))
            increment(&block)
        }
        return output.prefix(count)
    }

    private static func increment(_ data: inout Data) {
        for index in stride(from: data.count - 1, through: 0, by: -1) {
            data[index] &+= 1
            if data[index] != 0 { break }
        }
    }
}

struct AppleSRTCPKeySchedule: Equatable, Sendable {
    let cipherKey: Data
    let authenticationKey: Data
    let salt: Data

    init(blob: Data) throws {
        guard blob.count == AppleMediaKeys.blobLength else { throw AppleSRTPError.invalidKeyBlob }
        let masterKey = blob.prefix(32)
        let masterSalt = blob.suffix(14)
        cipherKey = try AppleMediaKeyDerivation.derive(
            masterKey: masterKey, masterSalt: masterSalt, label: 3, count: 32
        )
        authenticationKey = try AppleMediaKeyDerivation.derive(
            masterKey: masterKey, masterSalt: masterSalt, label: 4, count: 20
        )
        salt = try AppleMediaKeyDerivation.derive(
            masterKey: masterKey, masterSalt: masterSalt, label: 5, count: 14
        )
    }
}

final class AppleSRTCPEncryptor: @unchecked Sendable {
    private static let authenticationTagLength = 10
    private let lock = NSLock()
    private let keys: AppleSRTCPKeySchedule
    private var index: UInt32 = 0

    init(keyBlob: Data) throws {
        keys = try AppleSRTCPKeySchedule(blob: keyBlob)
    }

    func protect(_ packet: Data) throws -> Data {
        try lock.withCriticalSection {
            guard packet.count >= 8 else { throw AppleSRTPError.invalidPacket }
            let packetIndex = index & 0x7fff_ffff
            index = (packetIndex &+ 1) & 0x7fff_ffff
            let source = try packet.uint32BE(at: 4)
            let header = packet.prefix(8)
            let ciphertext = try Cryptography.cryptAESCTR(
                packet.dropFirst(8),
                key: keys.cipherKey,
                iv: initializationVector(source: source, index: packetIndex)
            )
            var body = Data(header)
            body.append(ciphertext)
            body.appendUInt32BE(0x8000_0000 | packetIndex)
            let code = HMAC<Insecure.SHA1>.authenticationCode(
                for: body,
                using: SymmetricKey(data: keys.authenticationKey)
            )
            body.append(contentsOf: code.prefix(Self.authenticationTagLength))
            return body
        }
    }

    private func initializationVector(source: UInt32, index: UInt32) -> Data {
        var vector = Data(keys.salt) + Data(repeating: 0, count: 2)
        for offset in 0..<4 {
            vector[4 + offset] ^= UInt8(truncatingIfNeeded: source >> UInt32(24 - offset * 8))
            vector[10 + offset] ^= UInt8(truncatingIfNeeded: index >> UInt32(24 - offset * 8))
        }
        return vector
    }
}

final class AppleSRTPDecryptor: @unchecked Sendable {
    private struct SourceState {
        var rolloverCounter: UInt32 = 0
        var maximumSequence: UInt16 = 0
        var isInitialized = false
    }

    private static let authenticationTagLength = 10
    private let lock = NSLock()
    private let keys: AppleSRTPKeySchedule
    private var states = [UInt32: SourceState]()

    init(keyBlob: Data) throws {
        keys = try AppleSRTPKeySchedule(blob: keyBlob)
    }

    func decrypt(_ datagram: Data) throws -> AppleRTPPacket {
        try lock.withCriticalSection {
            guard datagram.count >= 22 else { throw AppleSRTPError.invalidPacket }
            let bodyLength = datagram.count - Self.authenticationTagLength
            let sequence = try datagram.uint16BE(at: 2)
            let timestamp = try datagram.uint32BE(at: 4)
            let source = try datagram.uint32BE(at: 8)
            let state = states[source] ?? SourceState()
            let guess = rolloverGuess(sequence: sequence, state: state)
            let candidates = [guess, state.rolloverCounter, guess &+ 1, guess == 0 ? 0 : guess - 1]
                .reduce(into: [UInt32]()) { if !$0.contains($1) { $0.append($1) } }

            for rollover in candidates {
                guard authenticates(datagram, bodyLength: bodyLength, rollover: rollover) else { continue }
                let headerLength = try rtpHeaderLength(datagram, bodyLength: bodyLength)
                let header = datagram.prefix(headerLength)
                let ciphertext = datagram.subdata(in: headerLength..<bodyLength)
                let index = UInt64(rollover) << 16 | UInt64(sequence)
                let payload = try Cryptography.cryptAESCTR(
                    ciphertext,
                    key: keys.cipherKey,
                    iv: initializationVector(source: source, index: index)
                )
                update(source: source, rollover: rollover, sequence: sequence)
                return AppleRTPPacket(
                    header: header,
                    payload: payload,
                    sequenceNumber: sequence,
                    timestamp: timestamp,
                    synchronizationSource: source,
                    payloadType: datagram[1] & 0x7f,
                    marker: datagram[1] & 0x80 != 0
                )
            }
            throw AppleSRTPError.authenticationFailed
        }
    }

    private func authenticates(_ packet: Data, bodyLength: Int, rollover: UInt32) -> Bool {
        var authenticated = packet.prefix(bodyLength)
        authenticated.appendUInt32BE(rollover)
        let code = HMAC<Insecure.SHA1>.authenticationCode(
            for: authenticated,
            using: SymmetricKey(data: keys.authenticationKey)
        )
        let expected = Data(code.prefix(Self.authenticationTagLength))
        let actual = packet.suffix(Self.authenticationTagLength)
        return zip(expected, actual).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func rtpHeaderLength(_ packet: Data, bodyLength: Int) throws -> Int {
        let first = packet[0]
        guard first >> 6 == 2 else { throw AppleSRTPError.invalidPacket }
        var length = 12 + Int(first & 0x0f) * 4
        guard length <= bodyLength else { throw AppleSRTPError.invalidPacket }
        if first & 0x10 != 0 {
            guard length + 4 <= bodyLength else { throw AppleSRTPError.invalidPacket }
            let words = try Int(packet.uint16BE(at: length + 2))
            length += 4 + words * 4
        }
        guard length <= bodyLength else { throw AppleSRTPError.invalidPacket }
        return length
    }

    private func rolloverGuess(sequence: UInt16, state: SourceState) -> UInt32 {
        guard state.isInitialized else { return 0 }
        let difference = Int(sequence) - Int(state.maximumSequence)
        if difference > 0x7fff { return state.rolloverCounter == 0 ? 0 : state.rolloverCounter - 1 }
        if difference < -0x7fff { return state.rolloverCounter &+ 1 }
        return state.rolloverCounter
    }

    private func update(source: UInt32, rollover: UInt32, sequence: UInt16) {
        var state = states[source] ?? SourceState()
        let incoming = UInt64(rollover) << 16 | UInt64(sequence)
        let current = UInt64(state.rolloverCounter) << 16 | UInt64(state.maximumSequence)
        if !state.isInitialized || incoming > current {
            state.rolloverCounter = rollover
            state.maximumSequence = sequence
            state.isInitialized = true
            states[source] = state
        }
    }

    private func initializationVector(source: UInt32, index: UInt64) -> Data {
        var vector = Data(keys.salt) + Data(repeating: 0, count: 2)
        for offset in 0..<4 {
            vector[4 + offset] ^= UInt8(truncatingIfNeeded: source >> UInt32(24 - offset * 8))
        }
        for offset in 0..<6 {
            vector[8 + offset] ^= UInt8(truncatingIfNeeded: index >> UInt64(40 - offset * 8))
        }
        return vector
    }
}

enum AppleSRTPError: LocalizedError, Equatable {
    case invalidKeyBlob
    case invalidPacket
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .invalidKeyBlob: "The media encryption key is invalid."
        case .invalidPacket: "The Mac sent an invalid media packet."
        case .authenticationFailed: "A media packet failed authentication."
        }
    }
}

private extension NSLock {
    func withCriticalSection<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
