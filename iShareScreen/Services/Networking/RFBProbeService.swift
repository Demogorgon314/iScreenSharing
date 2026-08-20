import Foundation
import Network

struct RFBProbeResult: Equatable, Sendable {
    let serverVersion: RFBVersion
    let securityTypes: [RFBSecurityType]
}

protocol RFBProbing: Sendable {
    func probe(_ endpoint: ConnectionEndpoint) async throws -> RFBProbeResult
}

struct RFBProbeService: RFBProbing {
    func probe(_ endpoint: ConnectionEndpoint) async throws -> RFBProbeResult {
        let connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: NWEndpoint.Port(rawValue: endpoint.port)!,
            using: .tcp
        )
        let transport = NWConnectionTransport(connection: connection)
        defer { transport.cancel() }

        try await transport.start()
        let banner = try await transport.receiveExactly(RFBProtocol.bannerLength)
        let version = try RFBProtocol.parseVersion(banner)
        try await transport.send(RFBProtocol.appleVersion)
        let countData = try await transport.receiveExactly(1)
        let count = try RFBProtocol.parseSecurityTypeCount(countData)
        let types = try RFBProtocol.parseSecurityTypes(
            try await transport.receiveExactly(count),
            expectedCount: count
        )
        return RFBProbeResult(serverVersion: version, securityTypes: types)
    }
}

private final class NWConnectionTransport: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.isharescreen.rfb-transport")

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let gate = ContinuationGate()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        gate.performOnce { continuation.resume() }
                    case .failed(let error), .waiting(let error):
                        gate.performOnce {
                            continuation.resume(throwing: RFBNetworkError.connectionFailed(error.localizedDescription))
                        }
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

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let message):
            "Couldn’t connect to the Mac. \(message)"
        case .connectionClosed:
            "The Mac closed the connection unexpectedly."
        }
    }
}
