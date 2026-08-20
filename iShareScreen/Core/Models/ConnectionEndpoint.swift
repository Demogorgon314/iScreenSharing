import Foundation

struct ConnectionEndpoint: Hashable, Codable, Sendable {
    static let defaultPort: UInt16 = 5900

    let host: String
    let port: UInt16

    init(host: String, port: UInt16 = defaultPort) throws {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty, !normalizedHost.contains(where: { $0.isWhitespace }) else {
            throw ConnectionEndpointError.invalidHost
        }
        self.host = normalizedHost
        self.port = port
    }

    init(_ input: String) throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ConnectionEndpointError.empty
        }

        let candidate = trimmed.contains("://") ? trimmed : "vnc://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              components.scheme?.lowercased() == "vnc",
              let parsedHost = components.host,
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil else {
            throw ConnectionEndpointError.invalidFormat
        }
        let host = parsedHost.hasPrefix("[") && parsedHost.hasSuffix("]")
            ? String(parsedHost.dropFirst().dropLast())
            : parsedHost

        guard let parsedPort = components.port else {
            try self.init(host: host)
            return
        }
        guard (1...Int(UInt16.max)).contains(parsedPort) else {
            throw ConnectionEndpointError.invalidPort
        }
        try self.init(host: host, port: UInt16(parsedPort))
    }

    var displayName: String {
        port == Self.defaultPort ? host : "\(host):\(port)"
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = "vnc"
        components.host = host
        if port != Self.defaultPort {
            components.port = Int(port)
        }
        return components.url!
    }
}

enum ConnectionEndpointError: LocalizedError, Equatable {
    case empty
    case invalidFormat
    case invalidHost
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .empty:
            "Enter a hostname or IP address."
        case .invalidFormat, .invalidHost:
            "Enter a valid hostname or vnc:// address."
        case .invalidPort:
            "The port must be between 1 and 65535."
        }
    }
}
