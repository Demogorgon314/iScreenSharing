import Foundation
import Network

final class NWConnectionTransport: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.isharescreen.rfb-transport")

    init(endpoint: ConnectionEndpoint) {
        connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: NWEndpoint.Port(rawValue: endpoint.port)!,
            using: .tcp
        )
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

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let message):
            "Couldn’t connect to the Mac. \(message)"
        case .connectionClosed:
            "The Mac closed the connection unexpectedly."
        case .invalidReadLength:
            "The host requested an invalid amount of protocol data."
        }
    }
}

