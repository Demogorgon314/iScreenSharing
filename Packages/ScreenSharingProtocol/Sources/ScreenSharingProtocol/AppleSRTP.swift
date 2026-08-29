import CryptoKit
import Foundation

public struct AppleRTPFramePacketInfo: Equatable, Sendable {
    public let totalPacketsPerFrame: UInt16
    public let frameSequenceNumber: UInt16

    public init(totalPacketsPerFrame: UInt16, frameSequenceNumber: UInt16) {
        self.totalPacketsPerFrame = totalPacketsPerFrame
        self.frameSequenceNumber = frameSequenceNumber
    }
}

public struct AppleRTPPacket: Equatable, Sendable {
    public let header: Data
    public let payload: Data
    public let sequenceNumber: UInt16
    public let timestamp: UInt32
    public let synchronizationSource: UInt32
    public let payloadType: UInt8
    public let marker: Bool

    public init(
        header: Data,
        payload: Data,
        sequenceNumber: UInt16,
        timestamp: UInt32,
        synchronizationSource: UInt32,
        payloadType: UInt8,
        marker: Bool
    ) {
        self.header = header
        self.payload = payload
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
        self.synchronizationSource = synchronizationSource
        self.payloadType = payloadType
        self.marker = marker
    }

    /// Apple inlines MCI Info ID 4 in the high nibble of the second extension
    /// header byte. Bit zero of that value requests acknowledgement of an LTR.
    public var isLongTermReferenceFrame: Bool {
        guard let mediaControlExtension else { return false }
        return mediaControlExtension.controlByte & 0x10 != 0
    }

    /// Apple MCI Info ID 6 carries the sender-declared packet count for this
    /// encoded frame. Info ID 4 is inline, so the Info ID 6 value is the first
    /// four-byte word after the Apple RTP extension header.
    public var framePacketInfo: AppleRTPFramePacketInfo? {
        guard let mediaControlExtension,
              mediaControlExtension.controlByte & 0x01 != 0 else { return nil }
        let infoOffset = mediaControlExtension.infoOffset
        guard infoOffset + 4 <= mediaControlExtension.endOffset,
              let totalPacketsPerFrame = BigEndianWire.uint16(from: header, at: infoOffset),
              let frameSequenceNumber = BigEndianWire.uint16(from: header, at: infoOffset + 2)
        else {
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
              let wordCount = BigEndianWire.uint16(from: header, at: extensionOffset + 2) else {
            return nil
        }
        let endOffset = extensionOffset + 4 + Int(wordCount) * 4
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
        do {
            cipherKey = try AppleMediaKeyDerivation.derive(
                masterKey: masterKey, masterSalt: masterSalt, label: 0, count: 32
            )
            authenticationKey = try AppleMediaKeyDerivation.derive(
                masterKey: masterKey, masterSalt: masterSalt, label: 1, count: 20
            )
            salt = try AppleMediaKeyDerivation.derive(
                masterKey: masterKey, masterSalt: masterSalt, label: 2, count: 14
            )
        } catch {
            throw AppleSRTPError.cryptographyFailed
        }
    }

    init(blob: Data) throws {
        guard blob.count == AppleMediaKeys.blobLength else {
            throw AppleSRTPError.invalidKeyBlob
        }
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
            output.append(try AppleProtocolAES.encryptECB(block, key: masterKey))
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
        guard blob.count == AppleMediaKeys.blobLength else {
            throw AppleSRTPError.invalidKeyBlob
        }
        let masterKey = blob.prefix(32)
        let masterSalt = blob.suffix(14)
        do {
            cipherKey = try AppleMediaKeyDerivation.derive(
                masterKey: masterKey, masterSalt: masterSalt, label: 3, count: 32
            )
            authenticationKey = try AppleMediaKeyDerivation.derive(
                masterKey: masterKey, masterSalt: masterSalt, label: 4, count: 20
            )
            salt = try AppleMediaKeyDerivation.derive(
                masterKey: masterKey, masterSalt: masterSalt, label: 5, count: 14
            )
        } catch {
            throw AppleSRTPError.cryptographyFailed
        }
    }
}

public final class AppleSRTCPEncryptor: @unchecked Sendable {
    private static let authenticationTagLength = 10
    private let lock = NSLock()
    private let keys: AppleSRTCPKeySchedule
    private var index: UInt32

    public convenience init(keyBlob: Data) throws {
        try self.init(keyBlob: keyBlob, index: 0)
    }

    init(keyBlob: Data, index: UInt32) throws {
        keys = try AppleSRTCPKeySchedule(blob: keyBlob)
        self.index = index & 0x7fff_ffff
    }

    public func protect(_ packet: Data) throws -> Data {
        try lock.withLock {
            guard packet.count >= 8 else { throw AppleSRTPError.invalidPacket }
            let packetIndex = index & 0x7fff_ffff
            let nextIndex = (packetIndex &+ 1) & 0x7fff_ffff
            guard let source = BigEndianWire.uint32(from: packet, at: 4) else {
                throw AppleSRTPError.invalidPacket
            }
            let ciphertext: Data
            do {
                ciphertext = try AppleProtocolAES.cryptCTR(
                    packet.dropFirst(8),
                    key: keys.cipherKey,
                    initializationVector: initializationVector(
                        source: source,
                        index: packetIndex
                    )
                )
            } catch {
                throw AppleSRTPError.cryptographyFailed
            }
            var body = Data(packet.prefix(8))
            body.append(ciphertext)
            BigEndianWire.append(0x8000_0000 | packetIndex, to: &body)
            let code = HMAC<Insecure.SHA1>.authenticationCode(
                for: body,
                using: SymmetricKey(data: keys.authenticationKey)
            )
            body.append(contentsOf: code.prefix(Self.authenticationTagLength))
            index = nextIndex
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

public final class AppleSRTPDecryptor: @unchecked Sendable {
    private struct SourceState {
        var rolloverCounter: UInt32 = 0
        var maximumSequence: UInt16 = 0
        var isInitialized = false
    }

    private static let authenticationTagLength = 10
    private let lock = NSLock()
    private let keys: AppleSRTPKeySchedule
    private var states = [UInt32: SourceState]()

    public init(keyBlob: Data) throws {
        keys = try AppleSRTPKeySchedule(blob: keyBlob)
    }

    public func decrypt(_ datagram: Data) throws -> AppleRTPPacket {
        try lock.withLock {
            guard datagram.count >= 22,
                  let sequence = BigEndianWire.uint16(from: datagram, at: 2),
                  let timestamp = BigEndianWire.uint32(from: datagram, at: 4),
                  let source = BigEndianWire.uint32(from: datagram, at: 8) else {
                throw AppleSRTPError.invalidPacket
            }
            let bodyLength = datagram.count - Self.authenticationTagLength
            let state = states[source] ?? SourceState()
            let guess = rolloverGuess(sequence: sequence, state: state)
            let candidates = [guess, state.rolloverCounter, guess &+ 1, guess == 0 ? 0 : guess - 1]
                .reduce(into: [UInt32]()) { if !$0.contains($1) { $0.append($1) } }

            for rollover in candidates {
                guard authenticates(datagram, bodyLength: bodyLength, rollover: rollover) else {
                    continue
                }
                let headerLength = try rtpHeaderLength(datagram, bodyLength: bodyLength)
                let ciphertext = datagram.subdata(in: headerLength..<bodyLength)
                let index = UInt64(rollover) << 16 | UInt64(sequence)
                let payload: Data
                do {
                    payload = try AppleProtocolAES.cryptCTR(
                        ciphertext,
                        key: keys.cipherKey,
                        initializationVector: initializationVector(source: source, index: index)
                    )
                } catch {
                    throw AppleSRTPError.cryptographyFailed
                }
                update(source: source, rollover: rollover, sequence: sequence)
                return AppleRTPPacket(
                    header: datagram.prefix(headerLength),
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
        var authenticated = Data(packet.prefix(bodyLength))
        BigEndianWire.append(rollover, to: &authenticated)
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
            guard length + 4 <= bodyLength,
                  let words = BigEndianWire.uint16(from: packet, at: length + 2) else {
                throw AppleSRTPError.invalidPacket
            }
            length += 4 + Int(words) * 4
        }
        guard length <= bodyLength else { throw AppleSRTPError.invalidPacket }
        return length
    }

    private func rolloverGuess(sequence: UInt16, state: SourceState) -> UInt32 {
        guard state.isInitialized else { return 0 }
        let difference = Int(sequence) - Int(state.maximumSequence)
        if difference > 0x7fff {
            return state.rolloverCounter == 0 ? 0 : state.rolloverCounter - 1
        }
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

public enum AppleSRTPError: LocalizedError, Equatable {
    case invalidKeyBlob
    case invalidPacket
    case authenticationFailed
    case cryptographyFailed

    public var errorDescription: String? {
        switch self {
        case .invalidKeyBlob:
            "The media encryption key is invalid."
        case .invalidPacket:
            "The Mac sent an invalid media packet."
        case .authenticationFailed:
            "A media packet failed authentication."
        case .cryptographyFailed:
            "A media packet could not be processed securely."
        }
    }
}
