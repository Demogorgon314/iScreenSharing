import Darwin
import struct ScreenSharingProtocol.RFBServerInfo
import XCTest
@testable import iScreenSharing

@MainActor
final class TCPReadCancellationTests: XCTestCase {
    func testCancellingDirectAuthenticationInterruptsSilentPeer() async throws {
        try await assertAuthenticationCancellation(connection: TCPReadTestConnection.direct())
    }

    func testCancellingTailscaleAuthenticationInterruptsSilentPeer() async throws {
        try await assertAuthenticationCancellation(connection: TCPReadTestConnection.tailscale())
    }

    func testAlreadyCancelledDirectAuthenticationClosesRouteWithoutReading() async throws {
        try await assertAuthenticationCancellation(
            connection: TCPReadTestConnection.direct(), alreadyCancelled: true
        )
    }

    func testAlreadyCancelledTailscaleAuthenticationClosesRouteWithoutReading() async throws {
        try await assertAuthenticationCancellation(
            connection: TCPReadTestConnection.tailscale(), alreadyCancelled: true
        )
    }

    func testCancellingDirectAuthenticationDiscardsPartialBanner() async throws {
        let connection = try await TCPReadTestConnection.direct()
        try await assertAuthenticationCancellation(connection: connection, partialBanner: true)
    }

    func testCancellingTailscaleAuthenticationDiscardsPartialBanner() async throws {
        try await assertAuthenticationCancellation(
            connection: TCPReadTestConnection.tailscale(), partialBanner: true
        )
    }

    func testCancellingDirectActivationInterruptsEncryptionNegotiation() async throws {
        try await assertActivationCancellation(connection: TCPReadTestConnection.direct())
    }

    func testCancellingTailscaleActivationInterruptsEncryptionNegotiation() async throws {
        try await assertActivationCancellation(connection: TCPReadTestConnection.tailscale())
    }

    func testDirectReaderCancellationPreservesOwnerOrderedShutdown() async throws {
        try await assertReaderCancellationPreservesOwnerShutdown(connection: TCPReadTestConnection.direct())
    }

    func testTailscaleReaderCancellationPreservesOwnerOrderedShutdown() async throws {
        try await assertReaderCancellationPreservesOwnerShutdown(connection: TCPReadTestConnection.tailscale())
    }

    private func assertReaderCancellationPreservesOwnerShutdown(
        connection: TCPReadTestConnection
    ) async throws {
        defer { connection.close() }
        let started = expectation(description: "Control reader entered TCP read")
        let observed = ReadTestTransport(base: connection.transport) { started.fulfill() }
        let reader = Task { try await observed.receiveExactly(1) }
        await fulfillment(of: [started], timeout: 2)
        reader.cancel()

        // A ready session stops its reader before sending its final control
        // message. The session owner decides when the transport closes.
        do {
            try await connection.transport.send(Data([0x01]))
        } catch {
            XCTFail("Reader cancellation closed the owner's write path: \(error)")
        }
        connection.transport.cancel()
        _ = await reader.result
    }

    private func assertAuthenticationCancellation(
        connection: TCPReadTestConnection,
        alreadyCancelled: Bool = false,
        partialBanner: Bool = false
    ) async throws {
        defer { connection.close() }
        if partialBanner { try connection.send(Data("RFB".utf8)) }
        let started = alreadyCancelled ? nil : expectation(description: "Authentication entered TCP read")
        let observed = ReadTestTransport(base: connection.transport) { started?.fulfill() }
        let route = ManagedSessionRoute(
            control: observed,
            remoteAddress: try ResolvedRemoteAddress(numericHost: "127.0.0.1", port: 5900),
            sharingType: .highPerformance
        ) { _, _ in throw SessionRouteError.closed }
        let service = RFBAuthenticationService(routeOpener: ReadTestRouteOpener(route: route))
        let finished = expectation(description: "Cancelled authentication finished without peer data")
        let authentication = Task {
            if alreadyCancelled { withUnsafeCurrentTask { $0?.cancel() } }
            defer { finished.fulfill() }
            return try await service.connect(
                to: ConnectionEndpoint(host: "127.0.0.1"),
                credentials: ScreenSharingCredentials(username: "viewer", password: "test-password")
            )
        }
        if let started {
            await fulfillment(of: [started], timeout: 2)
            authentication.cancel()
        }
        await fulfillment(of: [finished], timeout: 1)

        // Also drain a failing implementation, so the regression cannot leave a
        // suspended task or socket behind after its deadline assertion fails.
        connection.transport.cancel()
        switch await authentication.result {
        case .success:
            XCTFail("Cancelled authentication must not return a session")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }
        XCTAssertEqual(observed.cancelCount, 1)
        if alreadyCancelled { XCTAssertEqual(observed.readCount, 0) }
    }

    private func assertActivationCancellation(connection: TCPReadTestConnection) async throws {
        defer { connection.close() }
        let started = expectation(description: "Encryption negotiation entered TCP read")
        let finished = expectation(description: "Cancelled activation finished without rekey data")
        let observed = ReadTestTransport(base: connection.transport) { started.fulfill() }
        let endpoint = try ConnectionEndpoint(host: "127.0.0.1")
        let session = RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: try ResolvedRemoteAddress(numericHost: "127.0.0.1", port: 5900),
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(
                width: 1920, height: 1080,
                pixelFormat: Data(repeating: 0, count: 16), name: "Test Mac"
            ),
            transport: observed
        )
        let suiteName = "TCPReadCancellationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let activation = SessionActivation(
            authenticator: ReadTestAuthenticator(session: session),
            connectionStore: ConnectionStore(defaults: defaults),
            sessionFeaturePreferences: SessionFeaturePreferences(defaults: defaults)
        )
        let task = Task {
            defer { finished.fulfill() }
            return try await activation.activate(
                endpoint: endpoint,
                credentials: ScreenSharingCredentials(username: "viewer", password: "test-password"),
                configuration: SessionActivationConfiguration(
                    sharingType: .highPerformance, standardQuality: .high,
                    virtualDisplayCount: .one, requestedDisplaySizes: [.fixed1080p]
                )
            )
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await fulfillment(of: [finished], timeout: 1)
        connection.transport.cancel()
        switch await task.result {
        case .success:
            XCTFail("Cancelled activation must not return a ready session")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }
        XCTAssertNil(session.videoStream)
        XCTAssertEqual(observed.cancelCount, 1)
    }
}

private struct ReadTestAuthenticator: RFBAuthenticating {
    let session: RFBAuthenticatedSession

    func connect(
        to endpoint: ConnectionEndpoint,
        credentials: ScreenSharingCredentials,
        sharingType: ScreenSharingType
    ) async throws -> RFBAuthenticatedSession {
        session
    }
}

private final class ReadTestTransport: RFBTransport, @unchecked Sendable {
    private let base: any RFBTransport
    private let onRead: @Sendable () -> Void
    private let lock = NSLock()
    private var reads = 0
    private var cancellations = 0

    init(base: any RFBTransport, onRead: @escaping @Sendable () -> Void) {
        self.base = base
        self.onRead = onRead
    }

    var readCount: Int { lock.withLock { reads } }
    var cancelCount: Int { lock.withLock { cancellations } }

    func start(timeout: Duration) async throws { try await base.start(timeout: timeout) }
    func send(_ data: Data) async throws { try await base.send(data) }
    func receiveExactly(_ length: Int) async throws -> Data {
        lock.withLock { reads += 1 }
        onRead()
        return try await base.receiveExactly(length)
    }
    func cancel() {
        lock.withLock { cancellations += 1 }
        base.cancel()
    }
}

private struct ReadTestRouteOpener: SessionRouteOpening {
    let route: any OpenSessionRoute

    func open(
        _ endpoint: ConnectionEndpoint,
        sharingType: ScreenSharingType
    ) async throws -> any OpenSessionRoute {
        route
    }
}

private final class TCPReadTestConnection: @unchecked Sendable {
    let transport: any RFBTransport
    let peer: Int32

    private init(transport: any RFBTransport, peer: Int32) {
        self.transport = transport
        self.peer = peer
    }

    static func direct() async throws -> TCPReadTestConnection {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw posixError() }
        defer { Darwin.close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listener, 1) == 0 else { throw posixError() }
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let inspected = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &addressLength)
            }
        }
        guard inspected == 0 else { throw posixError() }
        let transport = NWConnectionTransport(endpoint: try ConnectionEndpoint(
            host: "127.0.0.1", port: UInt16(bigEndian: address.sin_port)
        ))
        do {
            try await transport.start(timeout: .seconds(2))
            let peer = accept(listener, nil, nil)
            guard peer >= 0 else { throw posixError() }
            return TCPReadTestConnection(transport: transport, peer: peer)
        } catch {
            transport.cancel()
            throw error
        }
    }

    static func tailscale() throws -> TCPReadTestConnection {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw posixError()
        }
        return TCPReadTestConnection(
            transport: TailscaleTCPTransport(connectedFileDescriptor: descriptors[0]),
            peer: descriptors[1]
        )
    }

    func close() {
        transport.cancel()
        Darwin.close(peer)
    }

    func send(_ data: Data) throws {
        let count = data.withUnsafeBytes { Darwin.write(peer, $0.baseAddress, $0.count) }
        guard count == data.count else { throw Self.posixError() }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
