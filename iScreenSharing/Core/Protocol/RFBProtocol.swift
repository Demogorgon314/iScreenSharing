import Foundation

enum RFBProtocol {
    static let appleVersion = Data("RFB 003.889\n".utf8)
    static let bannerLength = 12

    static func parseVersion(_ data: Data) throws -> RFBVersion {
        guard data.count == bannerLength,
              let value = String(data: data, encoding: .ascii),
              value.hasPrefix("RFB "),
              value.hasSuffix("\n") else {
            throw RFBProtocolError.invalidVersionBanner
        }

        let version = value.dropFirst(4).dropLast()
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]),
              let minor = Int(parts[1]) else {
            throw RFBProtocolError.invalidVersionBanner
        }
        return RFBVersion(major: major, minor: minor)
    }

    static func parseSecurityTypeCount(_ data: Data) throws -> Int {
        guard data.count == 1, let count = data.first else {
            throw RFBProtocolError.invalidSecurityTypes
        }
        guard count > 0 else {
            throw RFBProtocolError.serverRejectedConnection
        }
        return Int(count)
    }

    static func parseSecurityTypes(_ data: Data, expectedCount: Int) throws -> [RFBSecurityType] {
        guard data.count == expectedCount else {
            throw RFBProtocolError.invalidSecurityTypes
        }
        return data.map(RFBSecurityType.init(rawValue:))
    }
}

struct RFBVersion: Equatable, Sendable {
    let major: Int
    let minor: Int
}

struct RFBSecurityType: RawRepresentable, Equatable, Hashable, Sendable {
    let rawValue: UInt8

    static let none = Self(rawValue: 1)
    static let vncAuthentication = Self(rawValue: 2)
    static let appleDiffieHellman = Self(rawValue: 30)
    static let appleRSA = Self(rawValue: 33)
    static let appleKerberos = Self(rawValue: 35)
    static let appleSRP = Self(rawValue: 36)
}

enum RFBProtocolError: LocalizedError, Equatable {
    case invalidVersionBanner
    case invalidSecurityTypes
    case serverRejectedConnection

    var errorDescription: String? {
        switch self {
        case .invalidVersionBanner:
            "The host did not return a valid Screen Sharing protocol banner."
        case .invalidSecurityTypes:
            "The host returned an invalid authentication list."
        case .serverRejectedConnection:
            "The host rejected the connection before authentication."
        }
    }
}

