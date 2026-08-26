import Foundation

struct AppleKeyboardInputSourceState: Equatable, Sendable {
    let field: UInt16
    let isSecureInput: Bool
    let identifier: String
}

enum AppleKeyboardInputSourceMessage {
    static func share(identifier: String?) throws -> Data {
        let identifierData = identifier.map { Data($0.utf8) } ?? Data()
        guard identifierData.count <= Int(UInt16.max) - 4 else {
            throw AppleKeyboardInputSourceError.identifierTooLong
        }
        var message = Data([0x1a, 0x00])
        message.appendUInt16BE(UInt16(identifierData.count + 4))
        message.appendUInt16BE(1)
        message.appendUInt16BE(UInt16(identifierData.count))
        message.append(identifierData)
        return message
    }

    static func state(from payload: Data) -> AppleKeyboardInputSourceState? {
        guard payload.count >= 8,
              let field = try? payload.uint16BE(at: 0),
              let flags = try? payload.uint32BE(at: 2),
              let length = try? Int(payload.uint16BE(at: 6)),
              length > 0,
              length <= payload.count - 8 else { return nil }
        let identifier = String(decoding: payload[8..<(8 + length)], as: UTF8.self)
        return AppleKeyboardInputSourceState(
            field: field,
            isSecureInput: flags & 1 != 0,
            identifier: identifier
        )
    }
}

enum AppleKeyboardInputSourceError: Error, Equatable {
    case identifierTooLong
}

