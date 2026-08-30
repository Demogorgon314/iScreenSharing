import Foundation

enum RFBEncodingList {
    enum Error: Swift.Error {
        case tooManyEncodings
    }

    static func message(_ encodings: [Int32]) throws -> Data {
        guard encodings.count <= Int(UInt16.max) else {
            throw Error.tooManyEncodings
        }
        var message = Data([0x02, 0x00])
        BigEndianWire.append(UInt16(encodings.count), to: &message)
        for encoding in encodings {
            BigEndianWire.append(UInt32(bitPattern: encoding), to: &message)
        }
        return message
    }
}
