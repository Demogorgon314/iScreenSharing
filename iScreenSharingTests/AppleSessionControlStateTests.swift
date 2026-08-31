import Combine
import Foundation
import enum ScreenSharingProtocol.AppleRFBMessages
import struct ScreenSharingProtocol.AppleCanvas
import struct ScreenSharingProtocol.RFBServerInfo
import XCTest
@testable import iScreenSharing

@MainActor
final class AppleSessionControlStateTests: XCTestCase {
    func testStandardModeSendsRemoteModeBeforeDisablingLocalInput() async throws {
        let harness = try makeHarness()
        let changed = expectation(description: "Mode changed")
        let observation = harness.state.$isChangingMode.dropFirst().sink { changing in
            if !changing { changed.fulfill() }
        }

        harness.state.toggleMode()

        await fulfillment(of: [changed], timeout: 1)
        XCTAssertTrue(harness.state.isObserving)
        XCTAssertNil(harness.state.errorMessage)
        XCTAssertEqual(harness.transport.sentMessages, [
            AppleRFBMessages.controlMode(observing: true),
        ])
        await harness.input.pointer(buttons: 0, x: 10, y: 20)
        XCTAssertEqual(harness.transport.sentMessages.count, 1)
        withExtendedLifetime(observation) {}
        harness.session.close()
    }

    func testStandardModeSendFailureDoesNotCommitObservationState() async throws {
        let harness = try makeHarness(failingSendNumbers: [1])
        let failed = expectation(description: "Mode change failed")
        let observation = harness.state.$isChangingMode.dropFirst().sink { changing in
            if !changing { failed.fulfill() }
        }

        harness.state.toggleMode()

        await fulfillment(of: [failed], timeout: 1)
        XCTAssertFalse(harness.state.isObserving)
        XCTAssertNotNil(harness.state.errorMessage)
        XCTAssertEqual(harness.transport.sentMessages, [
            AppleRFBMessages.controlMode(observing: true),
        ])
        withExtendedLifetime(observation) {}
        harness.session.close()
    }

    private func makeHarness(
        failingSendNumbers: Set<Int> = []
    ) throws -> SessionControlHarness {
        let transport = SessionControlTransport(
            failingSendNumbers: failingSendNumbers
        )
        let endpoint = try ConnectionEndpoint("example.local")
        let session = RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: try ResolvedRemoteAddress(
                numericHost: "127.0.0.1",
                port: 5900
            ),
            sharingType: .standard,
            masterKey: Data(),
            serverInfo: RFBServerInfo(
                width: 100,
                height: 100,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Test Mac"
            ),
            transport: transport
        )
        let input = AppleInputController(
            session: session,
            canvas: AppleCanvas(width: 100, height: 100, tileCount: 1)
        )
        session.install(inputController: input)
        let state = AppleSessionControlState(session: session)
        session.install(controlState: state)
        return SessionControlHarness(
            session: session,
            transport: transport,
            input: input,
            state: state
        )
    }
}

private struct SessionControlHarness {
    let session: RFBAuthenticatedSession
    let transport: SessionControlTransport
    let input: AppleInputController
    let state: AppleSessionControlState
}

private enum SessionControlTransportError: LocalizedError {
    case expected

    var errorDescription: String? { "The remote Mac rejected the mode change." }
}

private final class SessionControlTransport: RFBTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let failingSendNumbers: Set<Int>
    private var messages = [Data]()

    init(failingSendNumbers: Set<Int>) {
        self.failingSendNumbers = failingSendNumbers
    }

    var sentMessages: [Data] {
        lock.withSessionControlLock { messages }
    }

    func start(timeout: Duration) async throws {}

    func send(_ data: Data) async throws {
        let sendNumber = lock.withSessionControlLock { () -> Int in
            messages.append(data)
            return messages.count
        }
        if failingSendNumbers.contains(sendNumber) {
            throw SessionControlTransportError.expected
        }
    }

    func receiveExactly(_ length: Int) async throws -> Data {
        throw RFBNetworkError.connectionClosed
    }

    func cancel() {}
}

private extension NSLock {
    func withSessionControlLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
