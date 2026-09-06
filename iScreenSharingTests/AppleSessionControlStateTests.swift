import Carbon
import Combine
import Foundation
import enum ScreenSharingProtocol.AppleRFBMessages
import class ScreenSharingProtocol.AppleEncryptedRecordLayer
import struct ScreenSharingProtocol.AppleCanvas
import struct ScreenSharingProtocol.AppleRecordKeys
import struct ScreenSharingProtocol.RFBServerInfo
import XCTest
@testable import iScreenSharing

@MainActor
final class AppleSessionControlStateTests: XCTestCase {
    func testStandardMenuCommandFollowsKeyboardCleanupBeforeObservation() async throws {
        try await assertMenuCommandOrdering(sharingType: .standard)
    }

    func testHighPerformanceMenuCommandFollowsKeyboardCleanupBeforeObservation() async throws {
        try await assertMenuCommandOrdering(sharingType: .highPerformance)
    }

    func testQueuedRemoteCommandIsRejectedAfterInputCloses() async throws {
        let harness = try makeHarness()
        let gate = SessionControlGate()
        harness.input.enqueueInput { await gate.wait() }
        harness.input.perform(.missionControl)
        await harness.input.close()
        await gate.open()
        await harness.input.enqueueInput {}.value

        XCTAssertTrue(harness.transport.sentMessages.isEmpty)
        harness.session.close()
    }

    func testRemoteCommandsRespectQueuedObservationAndReturnToControl() async throws {
        let harness = try makeHarness()
        harness.state.toggleMode()
        harness.input.perform(.missionControl)
        await harness.input.enqueueInput {}.value

        harness.state.toggleMode()
        harness.input.perform(.missionControl)
        await harness.input.enqueueInput {}.value

        XCTAssertFalse(harness.state.isObserving)
        XCTAssertEqual(harness.transport.sentMessages, [
            Data([0x0a, 0, 0, 0]),
            Data([0x0a, 0, 0, 1]),
            Data([4, 1, 0, 0, 0x10, 0x08, 0xfd, 0x02]),
        ])
        harness.session.close()
    }

    func testStandardModeChangeWaitsForEarlierInputAndRejectsLaterInput() async throws {
        try await assertModeChangeOrdersInput(sharingType: .standard)
    }

    func testHighPerformanceModeChangeWaitsForEarlierInputAndRejectsLaterInput() async throws {
        try await assertModeChangeOrdersInput(sharingType: .highPerformance)
    }

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
        try await assertModeSendFailure(sharingType: .standard)
    }

    func testHighPerformanceModeSendFailureDoesNotCommitObservationState() async throws {
        try await assertModeSendFailure(sharingType: .highPerformance)
    }

    func testClosedInputRejectsQueuedModeChange() async throws {
        let harness = try makeHarness()
        let gate = SessionControlGate()
        harness.input.enqueueInput { await gate.wait() }
        harness.state.toggleMode()
        await harness.input.close()
        await gate.open()
        await harness.input.enqueueInput {}.value

        XCTAssertFalse(harness.state.isObserving)
        XCTAssertFalse(harness.state.isChangingMode)
        XCTAssertNotNil(harness.state.errorMessage)
        XCTAssertTrue(harness.transport.sentMessages.isEmpty)
        harness.session.close()
    }

    func testClosingInputDuringModeWriteDoesNotCommitObservationState() async throws {
        let gate = SessionControlGate()
        let harness = try makeHarness(sendGate: gate)
        let sending = expectation(description: "Mode write started")
        harness.transport.observeSend { sending.fulfill() }
        harness.state.toggleMode()
        await fulfillment(of: [sending], timeout: 1)
        harness.transport.observeSend(nil)
        XCTAssertFalse(harness.state.isObserving)
        XCTAssertTrue(harness.state.isChangingMode)

        await harness.input.close()
        await gate.open()
        await harness.input.enqueueInput {}.value

        XCTAssertFalse(harness.state.isObserving)
        XCTAssertFalse(harness.state.isChangingMode)
        XCTAssertNotNil(harness.state.errorMessage)
        XCTAssertEqual(harness.transport.sentMessages, [Data([0x0a, 0, 0, 0])])
        harness.session.close()
    }

    func testFailedReturnToControlKeepsObservationState() async throws {
        let harness = try makeHarness(failingSendNumbers: [2])
        harness.state.toggleMode()
        await harness.input.enqueueInput {}.value
        XCTAssertTrue(harness.state.isObserving)

        harness.state.toggleMode()
        await harness.input.enqueueInput {}.value

        XCTAssertTrue(harness.state.isObserving)
        XCTAssertFalse(harness.state.isChangingMode)
        XCTAssertNotNil(harness.state.errorMessage)
        XCTAssertEqual(harness.transport.sentMessages, [
            Data([0x0a, 0, 0, 0]), Data([0x0a, 0, 0, 1]),
        ])
        harness.session.close()
    }

    private func assertMenuCommandOrdering(sharingType: ScreenSharingType) async throws {
        let harness = try makeHarness(sharingType: sharingType)
        let capabilities = AppleRemoteSystemCapabilities()
        capabilities.receive(keySymbols: [AppleRemoteSystemCommand.missionControl.rawValue])
        harness.session.install(remoteSystemCapabilities: capabilities)
        let suiteName = "MenuCommandOrdering.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let commands = SessionCommandState(
            endpoint: harness.session.endpoint, session: harness.session,
            controlState: harness.state, preferences: SessionFeaturePreferences(defaults: defaults)
        )
        let source = UUID()
        let shift = AppleKeyboardKey(keyCode: 56, keyboardType: 40, symbols: [0xffe1])
        harness.input.receiveKeyboard(.modifiersChanged(shift, .shift, pressed: [.shift]), from: source)
        await harness.input.enqueueInput {}.value

        let gate = SessionControlGate()
        harness.input.enqueueInput { await gate.wait() }
        let overtookCleanup = expectation(description: "Menu command must wait for keyboard cleanup")
        overtookCleanup.isInverted = true
        harness.transport.observeSend { overtookCleanup.fulfill() }

        harness.input.releaseKeyboard(from: source)
        XCTAssertTrue(commands.canPerform(.missionControl))
        commands.perform(.missionControl)
        commands.setObserving(true)
        XCTAssertFalse(commands.canPerform(.missionControl))
        commands.perform(.missionControl)

        await fulfillment(of: [overtookCleanup], timeout: 0.1)
        harness.transport.observeSend(nil)
        await gate.open()
        await harness.input.enqueueInput {}.value

        XCTAssertTrue(commands.isObserving)
        XCTAssertFalse(commands.isChangingMode)
        XCTAssertNil(harness.state.errorMessage)
        let expected: [Data]
        if sharingType == .standard {
            expected = [
                Data([4, 1, 0, 0, 0, 0, 0xff, 0xe1]),
                Data([4, 0, 0, 0, 0, 0, 0xff, 0xe1]),
                Data([4, 1, 0, 0, 0x10, 0x08, 0xfd, 0x02]),
                Data([0x0a, 0, 0, 0]),
            ]
        } else {
            let encoder = AppleEncryptedRecordLayer(keys: try recordKeys())
            expected = try [
                encoder.encrypt(encoder.encryptKeyEvent(
                    isDown: true, keySymbol: 0xffe1, timestampDelta: 123, keyboardType: 40, keyCode: 56
                )),
                encoder.encrypt(encoder.encryptKeyEvent(
                    isDown: false, keySymbol: 0xffe1, timestampDelta: 0, keyboardType: 40, keyCode: 56
                )),
                encoder.encrypt(encoder.encryptKeyEvent(
                    isDown: true, keySymbol: 0x1008_fd02, timestampDelta: 0,
                    keyboardType: UInt16(LMGetKbdType()), keyCode: 0xfd02
                )),
                encoder.encrypt(Data([0x0a, 0, 0, 0])),
            ]
        }
        XCTAssertEqual(harness.transport.sentMessages, expected)
        harness.session.close()
    }

    private func assertModeSendFailure(sharingType: ScreenSharingType) async throws {
        let harness = try makeHarness(sharingType: sharingType, failingSendNumbers: [1])
        harness.state.toggleMode()
        await harness.input.enqueueInput {}.value

        XCTAssertFalse(harness.state.isObserving)
        XCTAssertFalse(harness.state.isChangingMode)
        XCTAssertNotNil(harness.state.errorMessage)
        var expected = Data([0x0a, 0, 0, 0])
        if sharingType == .highPerformance {
            expected = try AppleEncryptedRecordLayer(keys: recordKeys()).encrypt(expected)
        }
        XCTAssertEqual(harness.transport.sentMessages, [expected])
        harness.session.close()
    }

    private func assertModeChangeOrdersInput(sharingType: ScreenSharingType) async throws {
        let harness = try makeHarness(sharingType: sharingType)
        let gate = SessionControlGate()
        let blocked = expectation(description: "Earlier input is blocked")
        harness.input.enqueueInput {
            blocked.fulfill()
            await gate.wait()
        }
        await fulfillment(of: [blocked], timeout: 1)

        let overtookInput = expectation(description: "Mode must wait for earlier input")
        overtookInput.isInverted = true
        harness.transport.observeSend { overtookInput.fulfill() }
        let source = UUID()
        harness.input.receiveKeyboard(.keyDown(
            AppleKeyboardKey(keyCode: 0, keyboardType: 40, symbols: [97]),
            releaseImmediately: true
        ), from: source)
        harness.state.toggleMode()
        harness.input.receiveKeyboard(.keyDown(
            AppleKeyboardKey(keyCode: 1, keyboardType: 40, symbols: [115]),
            releaseImmediately: true
        ), from: source)

        await fulfillment(of: [overtookInput], timeout: 0.1)
        harness.transport.observeSend(nil)
        await gate.open()
        await harness.input.enqueueInput {}.value

        XCTAssertTrue(harness.state.isObserving)
        XCTAssertFalse(harness.state.isChangingMode)
        XCTAssertNil(harness.state.errorMessage)
        let encoder = AppleEncryptedRecordLayer(keys: try recordKeys())
        let expected: [Data]
        if sharingType == .standard {
            expected = [
                Data([4, 1, 0, 0, 0, 0, 0, 97]),
                Data([4, 0, 0, 0, 0, 0, 0, 97]),
                Data([0x0a, 0, 0, 0]),
            ]
        } else {
            expected = try [
                encoder.encrypt(encoder.encryptKeyEvent(
                    isDown: true, keySymbol: 97, timestampDelta: 123, keyboardType: 40, keyCode: 0
                )),
                encoder.encrypt(encoder.encryptKeyEvent(
                    isDown: false, keySymbol: 97, timestampDelta: 0, keyboardType: 40, keyCode: 0
                )),
                encoder.encrypt(Data([0x0a, 0, 0, 0])),
            ]
        }
        XCTAssertEqual(harness.transport.sentMessages, expected)

        harness.state.toggleMode()
        harness.input.receiveKeyboard(.keyDown(
            AppleKeyboardKey(keyCode: 1, keyboardType: 40, symbols: [115]),
            releaseImmediately: true
        ), from: source)
        await harness.input.enqueueInput {}.value

        XCTAssertFalse(harness.state.isObserving)
        XCTAssertFalse(harness.state.isChangingMode)
        XCTAssertNil(harness.state.errorMessage)
        let resumed: [Data]
        if sharingType == .standard {
            resumed = [
                Data([0x0a, 0, 0, 1]),
                Data([4, 1, 0, 0, 0, 0, 0, 115]),
                Data([4, 0, 0, 0, 0, 0, 0, 115]),
            ]
        } else {
            resumed = try [
                encoder.encrypt(Data([0x0a, 0, 0, 1])),
                encoder.encrypt(encoder.encryptKeyEvent(
                    isDown: true, keySymbol: 115, timestampDelta: 0, keyboardType: 40, keyCode: 1
                )),
                encoder.encrypt(encoder.encryptKeyEvent(
                    isDown: false, keySymbol: 115, timestampDelta: 0, keyboardType: 40, keyCode: 1
                )),
            ]
        }
        XCTAssertEqual(harness.transport.sentMessages, expected + resumed)
        harness.session.close()
    }

    private func recordKeys() throws -> AppleRecordKeys {
        try AppleRecordKeys(
            key: Data(repeating: 0x11, count: 16), initializationVector: Data(repeating: 0x22, count: 16)
        )
    }

    private func makeHarness(
        sharingType: ScreenSharingType = .standard,
        failingSendNumbers: Set<Int> = [],
        sendGate: SessionControlGate? = nil
    ) throws -> SessionControlHarness {
        let transport = SessionControlTransport(
            failingSendNumbers: failingSendNumbers,
            sendGate: sendGate
        )
        let endpoint = try ConnectionEndpoint("example.local")
        let session = RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: try ResolvedRemoteAddress(
                numericHost: "127.0.0.1",
                port: 5900
            ),
            sharingType: sharingType,
            masterKey: Data(),
            serverInfo: RFBServerInfo(
                width: 100,
                height: 100,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Test Mac"
            ),
            transport: transport
        )
        if sharingType == .highPerformance {
            session.install(recordLayer: AppleEncryptedRecordLayer(keys: try recordKeys()))
        }
        let input = AppleInputController(
            session: session,
            canvas: AppleCanvas(width: 100, height: 100, tileCount: 1),
            microseconds: { 123 }
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
    private let sendGate: SessionControlGate?
    private var messages = [Data]()
    private var sendObserver: (@Sendable () -> Void)?

    init(failingSendNumbers: Set<Int>, sendGate: SessionControlGate?) {
        self.failingSendNumbers = failingSendNumbers
        self.sendGate = sendGate
    }

    var sentMessages: [Data] {
        lock.withSessionControlLock { messages }
    }

    func start(timeout: Duration) async throws {}

    func observeSend(_ observer: (@Sendable () -> Void)?) {
        lock.withSessionControlLock { sendObserver = observer }
    }

    func send(_ data: Data) async throws {
        let (sendNumber, observer) = lock.withSessionControlLock {
            messages.append(data)
            return (messages.count, sendObserver)
        }
        observer?()
        await sendGate?.wait()
        if failingSendNumbers.contains(sendNumber) {
            throw SessionControlTransportError.expected
        }
    }

    func receiveExactly(_ length: Int) async throws -> Data {
        throw RFBNetworkError.connectionClosed
    }

    func cancel() {}
}

private actor SessionControlGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private extension NSLock {
    func withSessionControlLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
