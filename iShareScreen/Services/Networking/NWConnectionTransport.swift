import Foundation
import Network

final class NWConnectionTransport: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.isharescreen.rfb-transport")

    init(endpoint: ConnectionEndpoint, requiresIPv4: Bool = false) {
        connection = NWConnection(
            to: Self.networkEndpoint(for: endpoint),
            using: Self.parameters(requiresIPv4: requiresIPv4)
        )
    }

    static func parameters(requiresIPv4: Bool) -> NWParameters {
        let parameters = NWParameters.tcp
        guard requiresIPv4 else { return parameters }
        guard let options = parameters.defaultProtocolStack.internetProtocol
            as? NWProtocolIP.Options else {
            preconditionFailure("NWParameters.tcp must include IP protocol options")
        }
        options.version = .v4
        return parameters
    }

    static func networkEndpoint(for endpoint: ConnectionEndpoint) -> NWEndpoint {
        if let service = endpoint.bonjourService {
            return .service(
                name: service.name,
                type: service.type,
                domain: service.domain,
                interface: nil
            )
        }
        return .hostPort(
            host: NWEndpoint.Host(endpoint.host),
            port: NWEndpoint.Port(rawValue: endpoint.port)!
        )
    }

    func start(timeout: Duration = .seconds(15)) async throws -> String? {
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                try await self.waitUntilReady()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RFBNetworkError.connectionTimedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw RFBNetworkError.connectionClosed
            }
            return result
        }
    }

    private func waitUntilReady() async throws -> String? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, Error>) in
                let gate = ContinuationGate()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        gate.performOnce {
                            continuation.resume(
                                returning: Self.ipv4Host(
                                    from: self.connection.currentPath?.remoteEndpoint
                                )
                            )
                        }
                    case .failed(let error):
                        gate.performOnce {
                            continuation.resume(throwing: RFBNetworkError.connectionFailed(error.localizedDescription))
                        }
                    case .waiting:
                        break
                    case .cancelled:
                        gate.performOnce { continuation.resume(throwing: CancellationError()) }
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    static func ipv4Host(from endpoint: NWEndpoint?) -> String? {
        guard case let .hostPort(host, _) = endpoint,
              case let .ipv4(address) = host else {
            return nil
        }
        return address.debugDescription
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: RFBNetworkError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receiveExactly(_ length: Int) async throws -> Data {
        guard length >= 0 else { throw RFBNetworkError.invalidReadLength }
        var result = Data()
        while result.count < length {
            let remaining = length - result.count
            let chunk = try await receive(maximumLength: remaining)
            guard !chunk.isEmpty else {
                throw RFBNetworkError.connectionClosed
            }
            result.append(chunk)
        }
        return result
    }

    func cancel() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func receive(maximumLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: maximumLength
            ) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: RFBNetworkError.connectionFailed(error.localizedDescription))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: RFBNetworkError.connectionClosed)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasPerformed = false

    func performOnce(_ action: () -> Void) {
        lock.lock()
        guard !hasPerformed else {
            lock.unlock()
            return
        }
        hasPerformed = true
        lock.unlock()
        action()
    }
}

enum RFBNetworkError: LocalizedError {
    case connectionFailed(String)
    case connectionClosed
    case invalidReadLength
    case connectionTimedOut

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let message):
            "Couldn’t connect to the Mac. \(message)"
        case .connectionClosed:
            "The Mac closed the connection unexpectedly."
        case .invalidReadLength:
            "The host requested an invalid amount of protocol data."
        case .connectionTimedOut:
            "The connection timed out. Check Local Network access in System Settings and try again."
        }
    }
}
