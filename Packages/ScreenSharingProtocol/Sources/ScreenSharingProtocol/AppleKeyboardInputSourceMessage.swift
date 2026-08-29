import Foundation

/// The host's current keyboard input source state.
public struct AppleKeyboardInputSourceState: Equatable, Sendable {
    public let field: UInt16
    public let isSecureInput: Bool
    public let identifier: String

    public init(field: UInt16, isSecureInput: Bool, identifier: String) {
        self.field = field
        self.isSecureInput = isSecureInput
        self.identifier = identifier
    }
}

/// Encoder and parser for Apple's keyboard input-source sharing message.
public enum AppleKeyboardInputSourceMessage {
    public static func share(identifier: String?) throws -> Data {
        let identifierData = identifier.map { Data($0.utf8) } ?? Data()
        guard identifierData.count <= Int(UInt16.max) - 4 else {
            throw AppleKeyboardInputSourceError.identifierTooLong
        }
        var message = Data([0x1a, 0x00])
        BigEndianWire.append(UInt16(identifierData.count + 4), to: &message)
        BigEndianWire.append(UInt16(1), to: &message)
        BigEndianWire.append(UInt16(identifierData.count), to: &message)
        message.append(identifierData)
        return message
    }

    public static func state(from payload: Data) -> AppleKeyboardInputSourceState? {
        guard payload.count >= 8,
              let field = BigEndianWire.uint16(from: payload, at: 0),
              let flags = BigEndianWire.uint32(from: payload, at: 2),
              let rawLength = BigEndianWire.uint16(from: payload, at: 6) else {
            return nil
        }
        let length = Int(rawLength)
        guard length > 0, length <= payload.count - 8 else { return nil }
        let identifier = String(decoding: payload[8..<(8 + length)], as: UTF8.self)
        return AppleKeyboardInputSourceState(
            field: field,
            isSecureInput: flags & 1 != 0,
            identifier: identifier
        )
    }
}

public enum AppleKeyboardInputSourceError: Error, Equatable {
    case identifierTooLong
}
