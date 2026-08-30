import Foundation

/// Deterministic parsing and fixed wire values for the initial RFB handshake.
public enum RFBProtocol {
    /// Apple's Screen Sharing protocol banner sent after receiving the server banner.
    public static let appleVersion = Data("RFB 003.889\n".utf8)
    /// The exact byte length of an RFB version banner.
    public static let bannerLength = 12

    /// Parses an ASCII `RFB ddd.ddd\n` banner without accepting shortened fields.
    public static func parseVersion(_ data: Data) throws -> RFBVersion {
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

    /// Parses the server's non-zero, single-byte security-type count.
    public static func parseSecurityTypeCount(_ data: Data) throws -> Int {
        guard data.count == 1, let count = data.first else {
            throw RFBProtocolError.invalidSecurityTypes
        }
        guard count > 0 else {
            throw RFBProtocolError.serverRejectedConnection
        }
        return Int(count)
    }

    /// Preserves both known and unknown security type values when the payload length matches.
    public static func parseSecurityTypes(
        _ data: Data,
        expectedCount: Int
    ) throws -> [RFBSecurityType] {
        guard data.count == expectedCount else {
            throw RFBProtocolError.invalidSecurityTypes
        }
        return data.map(RFBSecurityType.init(rawValue:))
    }
}

/// The major and minor values carried by a validated RFB version banner.
public struct RFBVersion: Equatable, Sendable {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }
}

/// A raw RFB security type, including values unknown to this implementation.
public struct RFBSecurityType: RawRepresentable, Equatable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let none = Self(rawValue: 1)
    public static let vncAuthentication = Self(rawValue: 2)
    public static let appleDiffieHellman = Self(rawValue: 30)
    public static let appleRSA = Self(rawValue: 33)
    public static let appleKerberos = Self(rawValue: 35)
    public static let appleSRP = Self(rawValue: 36)
}

/// Observable failures produced while parsing the initial RFB handshake.
public enum RFBProtocolError: LocalizedError, Equatable {
    case invalidVersionBanner
    case invalidSecurityTypes
    case serverRejectedConnection

    public var errorDescription: String? {
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
