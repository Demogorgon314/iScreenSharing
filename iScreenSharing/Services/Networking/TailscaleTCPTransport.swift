import Darwin
import Foundation
import TailscaleKit

final class TailscaleTCPTransport: RFBTransport, @unchecked Sendable {
    private let endpoint: ConnectionEndpoint
    private let nodeProvider: any TailscaleNodeProviding
    private let connectQueue = DispatchQueue(label: "com.isharescreen.tailscale-tcp-connect")
    private let readQueue = DispatchQueue(label: "com.isharescreen.tailscale-tcp-read")
    private let writeQueue = DispatchQueue(label: "com.isharescreen.tailscale-tcp-write")
    private let state = FileDescriptorState()

    init(
        endpoint: ConnectionEndpoint,
        nodeProvider: any TailscaleNodeProviding = EmbeddedTailscaleRuntime.shared
    ) {
        self.endpoint = endpoint
        self.nodeProvider = nodeProvider
    }

    init(connectedFileDescriptor: Int32) {
        endpoint = try! ConnectionEndpoint(host: "127.0.0.1", route: .tailscale)
        nodeProvider = EmbeddedTailscaleRuntime.shared
        Self.disableSIGPIPE(on: connectedFileDescriptor)
        _ = state.install(connectedFileDescriptor)
    }

    func start(timeout: Duration = .seconds(15)) async throws {
        guard endpoint.route == .tailscale else {
            throw TailscaleTCPTransportError.invalidRoute
        }
        guard timeout > .zero else {
            throw RFBNetworkError.connectionTimedOut
        }
        try await nodeProvider.start()
        let handle = try await nodeProvider.tailscaleHandle()
        let address = Self.dialAddress(host: endpoint.host, port: endpoint.port)

        try await withCheckedThrowingContinuation { continuation in
            let gate = TailscaleDialCompletionGate(continuation: continuation)
            connectQueue.async { [self] in
                var connection: TailscaleConnection = 0
                let result = tailscale_dial(handle, NetProtocol.tcp.rawValue, address, &connection)
                guard result == 0 else {
                    gate.resume(
                        throwing: RFBNetworkError.connectionFailed(
                            Self.errorMessage(for: handle)
                        )
                    )
                    return
                }
                Self.disableSIGPIPE(on: connection)
                guard gate.claim() else {
                    Darwin.close(connection)
                    return
                }
                guard state.install(connection) else {
                    Darwin.close(connection)
                    continuation.resume(throwing: CancellationError())
                    return
                }
                continuation.resume()
            }
            Task {
                try? await Task.sleep(for: timeout)
                gate.resume(throwing: RFBNetworkError.connectionTimedOut)
            }
        }
    }

    func send(_ data: Data) async throws {
        if data.isEmpty { return }
        try await withCheckedThrowingContinuation { continuation in
            writeQueue.async { [state] in
                do {
                    let descriptor = try state.acquire()
                    defer { state.release() }
                    try data.withUnsafeBytes { bytes in
                        guard let baseAddress = bytes.baseAddress else { return }
                        var offset = 0
                        while offset < bytes.count {
                            let count = Darwin.write(
                                descriptor,
                                baseAddress.advanced(by: offset),
                                bytes.count - offset
                            )
                            if count > 0 {
                                offset += count
                            } else if count < 0, errno == EINTR {
                                continue
                            } else {
                                throw RFBNetworkError.connectionFailed(Self.posixMessage())
                            }
                        }
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func receiveExactly(_ length: Int) async throws -> Data {
        guard length >= 0 else { throw RFBNetworkError.invalidReadLength }
        if length == 0 { return Data() }
        return try await withCheckedThrowingContinuation { continuation in
            readQueue.async { [state] in
                do {
                    let descriptor = try state.acquire()
                    defer { state.release() }
                    var data = Data(count: length)
                    var offset = 0
                    try data.withUnsafeMutableBytes { bytes in
                        guard let baseAddress = bytes.baseAddress else { return }
                        while offset < length {
                            let count = Darwin.read(
                                descriptor,
                                baseAddress.advanced(by: offset),
                                length - offset
                            )
                            if count > 0 {
                                offset += count
                            } else if count == 0 {
                                throw RFBNetworkError.connectionClosed
                            } else if errno == EINTR {
                                continue
                            } else {
                                throw RFBNetworkError.connectionFailed(Self.posixMessage())
                            }
                        }
                    }
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func cancel() {
        state.cancel()
    }

    static func dialAddress(host: String, port: UInt16) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    private static func disableSIGPIPE(on descriptor: Int32) {
        var enabled: Int32 = 1
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout.size(ofValue: enabled))
        )
    }

    private static func errorMessage(for handle: TailscaleHandle) -> String {
        var buffer = [CChar](repeating: 0, count: 512)
        let result = tailscale_errmsg(handle, &buffer, buffer.count)
        guard result == 0 else { return "Embedded Tailscale dial failed." }
        let message = String(cString: buffer)
        return message.isEmpty ? "Embedded Tailscale dial failed." : message
    }

    private static func posixMessage() -> String {
        String(cString: strerror(errno))
    }
}

private final class FileDescriptorState: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var activeOperations = 0
    private var isCancelled = false

    func install(_ descriptor: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled, self.descriptor < 0 else { return false }
        self.descriptor = descriptor
        return true
    }

    func acquire() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled, descriptor >= 0 else {
            throw RFBNetworkError.connectionClosed
        }
        activeOperations += 1
        return descriptor
    }

    func release() {
        lock.lock()
        activeOperations -= 1
        let descriptorToClose = isCancelled && activeOperations == 0 ? descriptor : -1
        if descriptorToClose >= 0 { descriptor = -1 }
        lock.unlock()
        if descriptorToClose >= 0 { Darwin.close(descriptorToClose) }
    }

    func cancel() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        let currentDescriptor = descriptor
        let descriptorToClose = activeOperations == 0 ? currentDescriptor : -1
        if descriptorToClose >= 0 { descriptor = -1 }
        // Keep release() from closing and recycling the descriptor before the
        // shutdown that wakes its outstanding read/write operations.
        if currentDescriptor >= 0 { Darwin.shutdown(currentDescriptor, SHUT_RDWR) }
        lock.unlock()

        if descriptorToClose >= 0 { Darwin.close(descriptorToClose) }
    }
}

private final class TailscaleDialCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isCompleted = false
    private let continuation: CheckedContinuation<Void, Error>

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCompleted else { return false }
        isCompleted = true
        return true
    }

    func resume(throwing error: Error) {
        guard claim() else { return }
        continuation.resume(throwing: error)
    }
}

enum TailscaleTCPTransportError: LocalizedError {
    case invalidRoute

    var errorDescription: String? {
        "The connection is not configured to use embedded Tailscale."
    }
}
