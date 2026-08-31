import AppKit
import Combine
import Foundation
import class ScreenSharingProtocol.AppleEncryptedRecordLayer
import struct ScreenSharingProtocol.AppleCanvas
import struct ScreenSharingProtocol.AppleRecordKeys
import struct ScreenSharingProtocol.RFBServerInfo
import XCTest
@testable import iScreenSharing

@MainActor
final class AppleControlMessageServiceTests: XCTestCase {
    func testTransportFailureClosesInstalledSession() async throws {
        let harness = try makeHarness()
        defer { harness.manager.disconnect(harness.endpoint) }

        let removed = sessionRemovalExpectation(
            manager: harness.manager,
            endpoint: harness.endpoint
        )
        harness.service.start()
        await fulfillment(of: [harness.transport.readStarted], timeout: 1)

        harness.transport.failPendingRead()

        await fulfillment(
            of: [removed.expectation, harness.transport.cancelled],
            timeout: 1
        )
        XCTAssertNil(harness.manager.session(for: harness.endpoint))
        withExtendedLifetime(removed.observation) {}
    }

    func testInvalidEncryptedRecordClosesInstalledSession() async throws {
        let harness = try makeHarness()
        defer { harness.manager.disconnect(harness.endpoint) }

        let removed = sessionRemovalExpectation(
            manager: harness.manager,
            endpoint: harness.endpoint
        )
        harness.service.start()
        await fulfillment(of: [harness.transport.readStarted], timeout: 1)

        harness.transport.resumePendingRead(returning: Data([0, 1]))

        await fulfillment(
            of: [removed.expectation, harness.transport.cancelled],
            timeout: 1
        )
        XCTAssertNil(harness.manager.session(for: harness.endpoint))
        withExtendedLifetime(removed.observation) {}
    }

    private func makeHarness() throws -> ControlMessageHarness {
        let endpoint = try ConnectionEndpoint("example.local")
        let remoteAddress = try ResolvedRemoteAddress(
            numericHost: "127.0.0.1",
            port: endpoint.port
        )
        let transport = ControlledControlTransport(
            readStarted: expectation(description: "Control read started"),
            cancelled: expectation(description: "Control transport cancelled")
        )
        let session = RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: remoteAddress,
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(
                width: 1920,
                height: 1080,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Test Mac"
            ),
            transport: transport
        )
        session.install(recordLayer: AppleEncryptedRecordLayer(
            keys: try AppleRecordKeys(
                key: Data(repeating: 0x11, count: 16),
                initializationVector: Data(repeating: 0x22, count: 16)
            )
        ))
        let input = AppleInputController(
            session: session,
            canvas: AppleCanvas(width: 1920, height: 1080, tileCount: 4)
        )
        session.install(inputController: input)
        let clipboard = AppleClipboardService(
            pasteboard: NSPasteboard(name: .init("AppleControlMessageServiceTests")),
            isApplicationActive: { true }
        )
        let service = AppleControlMessageService(
            session: session,
            input: input,
            clipboard: clipboard,
            pendingMessages: []
        )
        session.install(
            controlMessageService: service,
            clipboardService: clipboard
        )
        let manager = SessionManager()
        manager.install(session)
        return ControlMessageHarness(
            endpoint: endpoint,
            transport: transport,
            service: service,
            manager: manager
        )
    }

    private func sessionRemovalExpectation(
        manager: SessionManager,
        endpoint: ConnectionEndpoint
    ) -> SessionRemovalObservation {
        let expectation = expectation(description: "Session removed")
        let observation = manager.$sessions.dropFirst().sink { sessions in
            if sessions[endpoint] == nil {
                expectation.fulfill()
            }
        }
        return SessionRemovalObservation(
            expectation: expectation,
            observation: observation
        )
    }
}

private struct ControlMessageHarness {
    let endpoint: ConnectionEndpoint
    let transport: ControlledControlTransport
    let service: AppleControlMessageService
    let manager: SessionManager
}

private struct SessionRemovalObservation {
    let expectation: XCTestExpectation
    let observation: AnyCancellable
}

private enum ControlledControlTransportError: Error {
    case connectionClosed
}

private final class ControlledControlTransport: RFBTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pendingRead: CheckedContinuation<Data, Error>?
    let readStarted: XCTestExpectation
    let cancelled: XCTestExpectation

    init(readStarted: XCTestExpectation, cancelled: XCTestExpectation) {
        self.readStarted = readStarted
        self.cancelled = cancelled
    }

    func start(timeout: Duration) async throws {}

    func send(_ data: Data) async throws {}

    func receiveExactly(_ length: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            precondition(pendingRead == nil)
            pendingRead = continuation
            lock.unlock()
            readStarted.fulfill()
        }
    }

    func resumePendingRead(returning data: Data) {
        takePendingRead()?.resume(returning: data)
    }

    func failPendingRead() {
        takePendingRead()?.resume(throwing: ControlledControlTransportError.connectionClosed)
    }

    func cancel() {
        cancelled.fulfill()
        failPendingRead()
    }

    private func takePendingRead() -> CheckedContinuation<Data, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let continuation = pendingRead
        pendingRead = nil
        return continuation
    }
}
