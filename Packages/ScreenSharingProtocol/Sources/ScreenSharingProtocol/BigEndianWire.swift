import Foundation

enum BigEndianWire {
    static func uint16(from data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, data.count >= offset + 2 else { return nil }
        return (UInt16(data[data.index(data.startIndex, offsetBy: offset)]) << 8)
            | UInt16(data[data.index(data.startIndex, offsetBy: offset + 1)])
    }

    static func uint32(from data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, data.count >= offset + 4 else { return nil }
        let first = UInt32(data[data.index(data.startIndex, offsetBy: offset)])
        let second = UInt32(data[data.index(data.startIndex, offsetBy: offset + 1)])
        let third = UInt32(data[data.index(data.startIndex, offsetBy: offset + 2)])
        let fourth = UInt32(data[data.index(data.startIndex, offsetBy: offset + 3)])
        return (first << 24) | (second << 16) | (third << 8) | fourth
    }

    static func append(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    static func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }
}
