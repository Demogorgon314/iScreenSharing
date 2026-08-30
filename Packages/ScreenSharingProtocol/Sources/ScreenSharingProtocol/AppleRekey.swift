import Foundation

/// The encrypted key-update payload carried by Apple framebuffer encoding 1103.
public struct AppleRekey: Equatable, Sendable {
    public static let encoding: Int32 = 1103
    public static let payloadLength = 36

    public let generation: UInt32
    public let encryptedKey: Data
    public let encryptedIV: Data

    public init(payload: Data) throws {
        guard payload.count == Self.payloadLength,
              let generation = BigEndianWire.uint32(from: payload, at: 0) else {
            throw AppleRekeyError.invalidPayload
        }
        self.generation = generation
        encryptedKey = payload.subdata(in: 4..<20)
        encryptedIV = payload.subdata(in: 20..<36)
    }
}

public enum AppleRekeyError: LocalizedError, Equatable {
    case invalidPayload

    public var errorDescription: String? {
        "The Mac returned an invalid encryption key update."
    }
}
