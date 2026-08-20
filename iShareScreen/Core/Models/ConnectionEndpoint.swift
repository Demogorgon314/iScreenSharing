import Foundation

struct ConnectionEndpoint: Hashable, Codable, Sendable {
    static let defaultPort: UInt16 = 5900

    let host: String
    let port: UInt16
    let bonjourService: BonjourServiceEndpoint?

    init(host: String, port: UInt16 = defaultPort) throws {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty, !normalizedHost.contains(where: { $0.isWhitespace }) else {
            throw ConnectionEndpointError.invalidHost
        }
        self.host = normalizedHost
        self.port = port
        bonjourService = nil
    }

    init(bonjourService: BonjourServiceEndpoint) {
        host = bonjourService.name
        port = Self.defaultPort
        self.bonjourService = bonjourService
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
        if let bonjourService { return bonjourService.name }
        return port == Self.defaultPort ? host : "\(host):\(port)"
    }

    var url: URL {
        if let bonjourService {
            var components = URLComponents()
            components.scheme = "vnc"
            components.host = "bonjour"
            components.queryItems = [
                URLQueryItem(name: "name", value: bonjourService.name),
                URLQueryItem(name: "type", value: bonjourService.type),
                URLQueryItem(name: "domain", value: bonjourService.domain)
            ]
            return components.url!
        }
        var components = URLComponents()
        components.scheme = "vnc"
        components.host = host
        if port != Self.defaultPort {
            components.port = Int(port)
        }
        return components.url!
    }
}

struct BonjourServiceEndpoint: Hashable, Codable, Sendable {
    let name: String
    let type: String
    let domain: String

    init(name: String, type: String = "_rfb._tcp", domain: String = "local.") throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = type.trimmingCharacters(in: .whitespacesAndNewlines)
        let domain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !type.isEmpty, !domain.isEmpty else {
            throw ConnectionEndpointError.invalidService
        }
        self.name = name
        self.type = type
        self.domain = domain
    }
}

enum ConnectionEndpointError: LocalizedError, Equatable {
    case empty
    case invalidFormat
    case invalidHost
    case invalidPort
    case invalidService

    var errorDescription: String? {
        switch self {
        case .empty:
            "Enter a hostname or IP address."
        case .invalidFormat, .invalidHost:
            "Enter a valid hostname or vnc:// address."
        case .invalidPort:
            "The port must be between 1 and 65535."
        case .invalidService:
            "The discovered Screen Sharing service is invalid."
        }
    }
}
