import Foundation
import XCTest
@testable import iScreenSharing

final class SessionRouteTests: XCTestCase {
    func testAuthenticationFailureClosesOpenedRoute() async throws {
        let transport = RecordingRouteTransport()
        let route = ManagedSessionRoute(
            control: transport,
            remoteAddress: try ResolvedRemoteAddress(numericHost: "127.0.0.1", port: 5900),
            sharingType: .standard
        ) { _, _ in RecordingMediaReceiver() }
        let service = RFBAuthenticationService(routeOpener: FixedRouteOpener(route: route))

        do {
            _ = try await service.connect(
                to: ConnectionEndpoint(host: "shared-mac.local"),
                credentials: ScreenSharingCredentials(username: "viewer", password: "secret"),
                sharingType: .standard
            )
            XCTFail("Expected the invalid server banner to fail authentication")
        } catch {
            XCTAssertEqual(transport.cancelCount, 1)
        }
    }

    func testOpenerSelectsOnlyEndpointRouteAdapter() async throws {
        let directRoute = try makeRoute(host: "127.0.0.1")
        let tailscaleRoute = try makeRoute(host: "100.64.0.10")
        let direct = RecordingRouteAdapter(route: directRoute)
        let tailscale = RecordingRouteAdapter(route: tailscaleRoute)
        let opener = SessionRouteOpener(direct: direct, tailscale: tailscale)

        let opened = try await opener.open(
            ConnectionEndpoint(host: "100.64.0.10", route: .tailscale),
            sharingType: .highPerformance
        )

        XCTAssertTrue(opened === tailscaleRoute)
        XCTAssertEqual(direct.openCount, 0)
        XCTAssertEqual(tailscale.openCount, 1)
    }

    func testDirectAdapterUsesSuccessfulControlAddressForMedia() async throws {
        let firstAddress = try ResolvedRemoteAddress(numericHost: "127.0.0.1", port: 5900)
        let secondAddress = try ResolvedRemoteAddress(numericHost: "127.0.0.2", port: 5900)
        let firstTransport = RecordingRouteTransport(startError: RouteTestError.connectionFailed)
        let secondTransport = RecordingRouteTransport()
        let transports = TransportSequence([firstTransport, secondTransport])
        let mediaAddress = AddressRecorder()
        let receiver = RecordingMediaReceiver()
        let adapter = DirectSessionRouteAdapter(
            addressResolver: StubAddressResolver(addresses: [firstAddress, secondAddress]),
            makeTransport: { _ in transports.next() },
            makeMedia: { address, _ in
                mediaAddress.record(address.numericHost)
                return receiver
            }
        )

        let route = try await adapter.open(
            ConnectionEndpoint(host: "shared-mac.local"),
            sharingType: .highPerformance
        )
        _ = try await route.openHighPerformanceMedia(displayCount: 1)

        XCTAssertEqual(firstTransport.cancelCount, 1)
        XCTAssertEqual(secondTransport.startCount, 1)
        XCTAssertEqual(route.remoteAddress.numericHost, "127.0.0.2")
        XCTAssertEqual(mediaAddress.value, "127.0.0.2")
    }

    func testDirectAdapterDoesNotFallbackAfterCancellation() async throws {
        let firstAddress = try ResolvedRemoteAddress(numericHost: "127.0.0.1", port: 5900)
        let secondAddress = try ResolvedRemoteAddress(numericHost: "127.0.0.2", port: 5900)
        let firstTransport = RecordingRouteTransport(startError: CancellationError())
        let secondTransport = RecordingRouteTransport()
        let transports = TransportSequence([firstTransport, secondTransport])
        let adapter = DirectSessionRouteAdapter(
            addressResolver: StubAddressResolver(addresses: [firstAddress, secondAddress]),
            makeTransport: { _ in transports.next() }
        )

        do {
            _ = try await adapter.open(
                ConnectionEndpoint(host: "shared-mac.local"),
                sharingType: .standard
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(firstTransport.cancelCount, 1)
            XCTAssertEqual(secondTransport.startCount, 0)
        }
    }

    func testStandardRouteNeverCreatesMedia() async throws {
        let mediaCreation = Counter()
        let route = ManagedSessionRoute(
            control: RecordingRouteTransport(),
            remoteAddress: try ResolvedRemoteAddress(numericHost: "127.0.0.1", port: 5900),
            sharingType: .standard
        ) { _, _ in
            mediaCreation.increment()
            return RecordingMediaReceiver()
        }

        do {
            _ = try await route.openHighPerformanceMedia(displayCount: 1)
            XCTFail("Expected media to be unavailable")
        } catch let error as SessionRouteError {
            XCTAssertEqual(error, .mediaUnavailableForStandardMode)
            XCTAssertEqual(mediaCreation.value, 0)
        }
    }

    func testRouteOpensMediaOnceAndClosesMediaBeforeControl() async throws {
        let events = EventRecorder()
        let transport = RecordingRouteTransport(onCancel: { events.record("control") })
        let receiver = RecordingMediaReceiver(onClose: { events.record("media") })
        let route = ManagedSessionRoute(
            control: transport,
            remoteAddress: try ResolvedRemoteAddress(numericHost: "127.0.0.1", port: 5900),
            sharingType: .highPerformance
        ) { _, _ in receiver }

        _ = try await route.openHighPerformanceMedia(displayCount: 1)
        do {
            _ = try await route.openHighPerformanceMedia(displayCount: 1)
            XCTFail("Expected duplicate media open to fail")
        } catch let error as SessionRouteError {
            XCTAssertEqual(error, .mediaAlreadyOpened)
        }

        route.close()
        route.close()

        XCTAssertEqual(events.values, ["media", "control"])
        XCTAssertEqual(receiver.closeCount, 1)
        XCTAssertEqual(transport.cancelCount, 1)
    }

    private func makeRoute(host: String) throws -> ManagedSessionRoute {
        ManagedSessionRoute(
            control: RecordingRouteTransport(),
            remoteAddress: try ResolvedRemoteAddress(numericHost: host, port: 5900),
            sharingType: .standard
        ) { _, _ in RecordingMediaReceiver() }
    }
}

private enum RouteTestError: Error {
    case connectionFailed
}

private struct StubAddressResolver: RemoteAddressResolving {
    let addresses: [ResolvedRemoteAddress]

    func resolve(_ endpoint: ConnectionEndpoint) async throws -> [ResolvedRemoteAddress] {
        addresses
    }
}

private struct FixedRouteOpener: SessionRouteOpening {
    let route: any OpenSessionRoute

    func open(
        _ endpoint: ConnectionEndpoint,
        sharingType: ScreenSharingType
    ) async throws -> any OpenSessionRoute {
        route
    }
}

private final class RecordingRouteAdapter: SessionRouteAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private let route: any OpenSessionRoute
    private var opens = 0

    init(route: any OpenSessionRoute) {
        self.route = route
    }

    var openCount: Int {
        lock.withRouteTestLock { opens }
    }

    func open(
        _ endpoint: ConnectionEndpoint,
        sharingType: ScreenSharingType
    ) async throws -> any OpenSessionRoute {
        lock.withRouteTestLock { opens += 1 }
        return route
    }
}

private final class RecordingRouteTransport: RFBTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let startError: Error?
    private let onCancel: @Sendable () -> Void
    private var starts = 0
    private var cancellations = 0

    init(
        startError: Error? = nil,
        onCancel: @escaping @Sendable () -> Void = { }
    ) {
        self.startError = startError
        self.onCancel = onCancel
    }

    var startCount: Int { lock.withRouteTestLock { starts } }
    var cancelCount: Int { lock.withRouteTestLock { cancellations } }

    func start(timeout: Duration) async throws {
        lock.withRouteTestLock { starts += 1 }
        if let startError { throw startError }
    }

    func send(_ data: Data) async throws { }

    func receiveExactly(_ length: Int) async throws -> Data {
        Data(repeating: 0, count: length)
    }

    func cancel() {
        lock.withRouteTestLock { cancellations += 1 }
        onCancel()
    }
}

private final class RecordingMediaReceiver: AppleMediaReceiving, @unchecked Sendable {
    private let lock = NSLock()
    private let onClose: @Sendable () -> Void
    private var closes = 0

    init(onClose: @escaping @Sendable () -> Void = { }) {
        self.onClose = onClose
    }

    var closeCount: Int { lock.withRouteTestLock { closes } }

    func startVideoDelivery(
        mediaStreamIndex: Int,
        on deliveryQueue: DispatchQueue,
        handler: @escaping AppleVideoDatagramHandler
    ) throws { }

    func stopVideoDelivery(mediaStreamIndex: Int) { }

    func videoReceiveBufferConfiguration(
        mediaStreamIndex: Int
    ) -> AppleMediaReceiveBufferConfiguration? {
        nil
    }

    func drainControlPackets() -> [Data] { [] }
    func sendControl(_ datagram: Data) throws { }
    func sendVideoControl(_ datagram: Data, mediaStreamIndex: Int) throws { }
    func configureRemotePorts(_ ports: AppleMediaPorts) throws { }
    func stopPunching() { }

    func close() {
        lock.withRouteTestLock { closes += 1 }
        onClose()
    }
}

private final class TransportSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [RecordingRouteTransport]

    init(_ transports: [RecordingRouteTransport]) {
        self.transports = transports
    }

    func next() -> RecordingRouteTransport {
        lock.withRouteTestLock { transports.removeFirst() }
    }
}

private final class AddressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValue: String?

    var value: String? { lock.withRouteTestLock { recordedValue } }

    func record(_ value: String) {
        lock.withRouteTestLock { recordedValue = value }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withRouteTestLock { count } }

    func increment() {
        lock.withRouteTestLock { count += 1 }
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events = [String]()

    var values: [String] { lock.withRouteTestLock { events } }

    func record(_ event: String) {
        lock.withRouteTestLock { events.append(event) }
    }
}

private extension NSLock {
    func withRouteTestLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
