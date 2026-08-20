import Foundation

struct RFBServerInfo: Equatable, Sendable {
    let width: UInt16
    let height: UInt16
    let pixelFormat: Data
    let name: String

    static func parse(header: Data, nameData: Data) throws -> Self {
        guard header.count == 24,
              nameData.count == Int(try header.uint32BE(at: 20)) else {
            throw RFBServerInitError.invalidMessage
        }
        let width = try header.uint16BE(at: 0)
        let height = try header.uint16BE(at: 2)
        guard width > 0, height > 0 else {
            throw RFBServerInitError.invalidDimensions
        }
        return Self(
            width: width,
            height: height,
            pixelFormat: header.subdata(in: 4..<20),
            name: String(decoding: nameData, as: UTF8.self)
        )
    }
}

enum RFBServerInitError: LocalizedError, Equatable {
    case invalidMessage
    case invalidDimensions
    case nameTooLong

    var errorDescription: String? {
        switch self {
        case .invalidMessage:
            "The Mac returned an invalid display description."
        case .invalidDimensions:
            "The Mac returned an invalid display size."
        case .nameTooLong:
            "The Mac returned a display name that is too large."
        }
    }
}

