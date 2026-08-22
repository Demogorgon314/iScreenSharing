import CFNetwork
import Darwin
import Foundation

struct ResolvedRemoteAddress: @unchecked Sendable {
    private var storage: sockaddr_storage
    let length: socklen_t

    init(numericHost: String, port: UInt16) throws {
        var hints = addrinfo(
            ai_flags: AI_NUMERICHOST | AI_NUMERICSERV,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(numericHost, String(port), &hints, &result)
        guard status == 0, let result else {
            throw RemoteAddressResolverError.invalidNumericAddress
        }
        defer { freeaddrinfo(result) }
        try self.init(copying: result.pointee.ai_addr, length: result.pointee.ai_addrlen)
    }

    init(copying pointer: UnsafePointer<sockaddr>, length: socklen_t) throws {
        let family = pointer.pointee.sa_family
        let expectedLength: Int
        switch Int32(family) {
        case AF_INET:
            expectedLength = MemoryLayout<sockaddr_in>.size
        case AF_INET6:
            expectedLength = MemoryLayout<sockaddr_in6>.size
        default:
            throw RemoteAddressResolverError.unsupportedAddressFamily
        }
        guard Int(length) >= expectedLength else {
            throw RemoteAddressResolverError.malformedAddress
        }

        var storage = sockaddr_storage()
        memcpy(&storage, pointer, expectedLength)
        self.storage = storage
        self.length = socklen_t(expectedLength)
    }

    var family: sa_family_t {
        var copy = storage
        return withUnsafePointer(to: &copy) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                $0.pointee.sa_family
            }
        }
    }

    var numericHost: String {
        var copy = storage
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = withUnsafePointer(to: &copy) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo(
                    $0,
                    length,
                    &buffer,
                    socklen_t(buffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
            }
        }
        precondition(status == 0, "Validated socket address must have a numeric host")
        return String(cString: buffer)
    }

    var port: UInt16 {
        var copy = storage
        return withUnsafePointer(to: &copy) { pointer in
            switch Int32(family) {
            case AF_INET:
                return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt16(bigEndian: $0.pointee.sin_port)
                }
            case AF_INET6:
                return pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    UInt16(bigEndian: $0.pointee.sin6_port)
                }
            default:
                preconditionFailure("Validated socket address has an unsupported family")
            }
        }
    }

    func withSockAddr<T>(
        port: UInt16,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
    ) rethrows -> T {
        var copy = storage
        withUnsafeMutablePointer(to: &copy) { pointer in
            switch Int32(family) {
            case AF_INET:
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_port = port.bigEndian
                }
            case AF_INET6:
                pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    $0.pointee.sin6_port = port.bigEndian
                }
            default:
                preconditionFailure("Validated socket address has an unsupported family")
            }
        }
        return try withUnsafePointer(to: &copy) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, length)
            }
        }
    }
}

struct RemoteAddressResolver: Sendable {
    func resolve(_ endpoint: ConnectionEndpoint) async throws -> [ResolvedRemoteAddress] {
        try await Task.detached {
            try Self.resolveSynchronously(endpoint)
        }.value
    }

    static func prioritized(
        _ addresses: [ResolvedRemoteAddress]
    ) -> [ResolvedRemoteAddress] {
        addresses.filter { Int32($0.family) == AF_INET }
            + addresses.filter { Int32($0.family) == AF_INET6 }
    }

    private static func resolveSynchronously(
        _ endpoint: ConnectionEndpoint
    ) throws -> [ResolvedRemoteAddress] {
        let addresses: [ResolvedRemoteAddress]
        if let service = endpoint.bonjourService {
            addresses = try resolveBonjour(service)
        } else {
            addresses = try resolveHost(endpoint.host, port: endpoint.port)
        }
        let prioritizedAddresses = prioritized(addresses)
        guard !prioritizedAddresses.isEmpty else {
            throw RemoteAddressResolverError.noUsableAddress
        }
        return prioritizedAddresses
    }

    private static func resolveHost(
        _ host: String,
        port: UInt16
    ) throws -> [ResolvedRemoteAddress] {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let result else {
            throw RemoteAddressResolverError.resolutionFailed
        }
        defer { freeaddrinfo(result) }

        var addresses = [ResolvedRemoteAddress]()
        var current: UnsafeMutablePointer<addrinfo>? = result
        while let info = current?.pointee {
            if let address = try? ResolvedRemoteAddress(
                copying: info.ai_addr,
                length: info.ai_addrlen
            ) {
                addresses.append(address)
            }
            current = info.ai_next
        }
        return addresses
    }

    private static func resolveBonjour(
        _ endpoint: BonjourServiceEndpoint
    ) throws -> [ResolvedRemoteAddress] {
        let service = CFNetServiceCreate(
            nil,
            endpoint.domain as CFString,
            endpoint.type as CFString,
            endpoint.name as CFString,
            0
        ).takeRetainedValue()
        var error = CFStreamError()
        guard CFNetServiceResolveWithTimeout(service, 5, &error),
              let addressing = CFNetServiceGetAddressing(service)?.takeUnretainedValue() else {
            throw RemoteAddressResolverError.resolutionFailed
        }

        var addresses = [ResolvedRemoteAddress]()
        for index in 0..<CFArrayGetCount(addressing) {
            guard let value = CFArrayGetValueAtIndex(addressing, index) else { continue }
            let data = Unmanaged<CFData>.fromOpaque(value).takeUnretainedValue()
            guard let bytes = CFDataGetBytePtr(data) else { continue }
            let pointer = UnsafeRawPointer(bytes).assumingMemoryBound(to: sockaddr.self)
            if let address = try? ResolvedRemoteAddress(
                copying: pointer,
                length: socklen_t(CFDataGetLength(data))
            ) {
                addresses.append(address)
            }
        }
        return addresses
    }
}

enum RemoteAddressResolverError: LocalizedError, Equatable {
    case invalidNumericAddress
    case malformedAddress
    case unsupportedAddressFamily
    case resolutionFailed
    case noUsableAddress

    var errorDescription: String? {
        switch self {
        case .invalidNumericAddress, .malformedAddress, .unsupportedAddressFamily:
            "The remote Mac provided an invalid network address."
        case .resolutionFailed, .noUsableAddress:
            "The remote Mac’s network address could not be resolved."
        }
    }
}
