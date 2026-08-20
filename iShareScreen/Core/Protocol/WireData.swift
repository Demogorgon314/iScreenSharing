import Foundation

extension Data {
    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendInt32BE(_ value: Int32) {
        appendUInt32BE(UInt32(bitPattern: value))
    }

    func uint16BE(at offset: Int) throws -> UInt16 {
        guard offset >= 0, count >= offset + 2 else {
            throw WireDataError.outOfBounds
        }
        return (UInt16(self[index(startIndex, offsetBy: offset)]) << 8)
            | UInt16(self[index(startIndex, offsetBy: offset + 1)])
    }

    func uint32BE(at offset: Int) throws -> UInt32 {
        guard offset >= 0, count >= offset + 4 else {
            throw WireDataError.outOfBounds
        }
        return (UInt32(self[index(startIndex, offsetBy: offset)]) << 24)
            | (UInt32(self[index(startIndex, offsetBy: offset + 1)]) << 16)
            | (UInt32(self[index(startIndex, offsetBy: offset + 2)]) << 8)
            | UInt32(self[index(startIndex, offsetBy: offset + 3)])
    }

    func int32BE(at offset: Int) throws -> Int32 {
        Int32(bitPattern: try uint32BE(at: offset))
    }
}

enum WireDataError: Error {
    case outOfBounds
}
