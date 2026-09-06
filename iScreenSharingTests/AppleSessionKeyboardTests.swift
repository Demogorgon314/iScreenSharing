import Foundation
import ScreenSharingProtocol
import XCTest
@testable import iScreenSharing

@MainActor
final class AppleSessionKeyboardTests: XCTestCase {
    func testTextScalarsRemainPairedAndDoNotStayHeld() async throws {
        let harness = try makeHarness()
        let source = UUID()
        let text = key(0, [0x61, 0x301, 0x1f642])
        harness.input.receiveKeyboard(.keyDown(text, releaseImmediately: true), from: source)
        harness.input.receiveKeyboard(.keyUp(keyCode: 0), from: source)
        harness.input.releaseKeyboard(from: source)
        await harness.input.enqueueInput {}.value

        try assertMessages(harness, [
            (key(0, [0x61]), true), (key(0, [0x61]), false),
            (key(0, [0x301]), true), (key(0, [0x301]), false),
            (key(0, [0x1f642]), true), (key(0, [0x1f642]), false),
        ])
    }

    func testHeldKeyRepeatsAndReleaseKeepOriginalSymbolsAndKeyboardType() async throws {
        let harness = try makeHarness()
        let source = UUID()
        let down = key(0, [97], keyboardType: 41)
        harness.input.receiveKeyboard(.keyDown(down, releaseImmediately: false), from: source)
        harness.input.receiveKeyboard(
            .keyDown(key(0, [65], keyboardType: 42), releaseImmediately: true), from: source
        )
        harness.input.receiveKeyboard(.keyUp(keyCode: 0), from: source)
        harness.input.receiveKeyboard(.keyUp(keyCode: 0), from: source)
        await harness.input.enqueueInput {}.value

        try assertMessages(harness, [(down, true), (down, true), (down, false)])
    }

    func testFocusCleanupReleasesHeldLettersBeforeModifiersAndIsIdempotent() async throws {
        let harness = try makeHarness()
        let source = UUID()
        let command = key(55, [0xffeb])
        let letter = key(0, [97])
        harness.input.receiveKeyboard(.modifiersChanged(command, .command, pressed: [.command]), from: source)
        harness.input.receiveKeyboard(.keyDown(letter, releaseImmediately: false), from: source)
        harness.input.releaseKeyboard(from: source)
        harness.input.releaseKeyboard(from: source)
        harness.input.receiveKeyboard(.keyUp(keyCode: 0), from: source)
        await harness.input.enqueueInput {}.value

        try assertMessages(harness, [(command, true), (letter, true), (letter, false), (command, false)])
    }

    func testLateOldCanvasCleanupDoesNotReleaseNewCanvasPress() async throws {
        let harness = try makeHarness()
        let oldSource = UUID()
        let newSource = UUID()
        let shift = key(56, [0xffe1])
        harness.input.receiveKeyboard(.modifiersChanged(shift, .shift, pressed: [.shift]), from: oldSource)
        harness.input.releaseKeyboard(from: oldSource)
        harness.input.receiveKeyboard(.modifiersChanged(shift, .shift, pressed: [.shift]), from: newSource)
        harness.input.releaseKeyboard(from: oldSource)
        harness.input.receiveKeyboard(.modifiersChanged(shift, .shift, pressed: []), from: oldSource)
        harness.input.receiveKeyboard(.modifiersChanged(shift, .shift, pressed: []), from: newSource)
        await harness.input.enqueueInput {}.value

        try assertMessages(harness, [(shift, true), (shift, false), (shift, true), (shift, false)])
    }

    func testRejectedKeyDownDoesNotLeavePressToReleaseAfterControlReturns() async throws {
        let harness = try makeHarness()
        let source = UUID()
        try await harness.input.setControlling(false)
        harness.input.receiveKeyboard(.keyDown(key(0, [97]), releaseImmediately: false), from: source)
        await harness.input.enqueueInput {}.value
        try await harness.input.setControlling(true)
        harness.input.receiveKeyboard(.keyUp(keyCode: 0), from: source)
        harness.input.releaseKeyboard(from: source)
        await harness.input.enqueueInput {}.value

        let encoder = AppleEncryptedRecordLayer(keys: harness.keys)
        XCTAssertEqual(harness.transport.sentMessages, try [
            encoder.encrypt(Data([0x0a, 0, 0, 0])),
            encoder.encrypt(Data([0x0a, 0, 0, 1])),
        ])
    }

    func testClosedInputRejectsQueuedKeyboardEventsAndCleanupWrites() async throws {
        let harness = try makeHarness()
        let source = UUID()
        let letter = key(0, [97])
        harness.input.receiveKeyboard(.keyDown(letter, releaseImmediately: false), from: source)
        await harness.input.enqueueInput {}.value
        await harness.input.close()
        harness.input.receiveKeyboard(.keyDown(key(1, [115]), releaseImmediately: true), from: source)
        harness.input.releaseKeyboard(from: source)
        await harness.input.enqueueInput {}.value

        try assertMessages(harness, [(letter, true)])
    }

    func testStandardModeUsesTheSamePairingThroughStandardWireMessages() async throws {
        let harness = try makeHarness(sharingType: .standard)
        let source = UUID()
        let command = key(55, [0xffeb])
        let letter = key(0, [97])
        harness.input.receiveKeyboard(.modifiersChanged(command, .command, pressed: [.command]), from: source)
        harness.input.receiveKeyboard(.keyDown(letter, releaseImmediately: false), from: source)
        harness.input.receiveKeyboard(.modifiersChanged(command, .command, pressed: []), from: source)
        harness.input.receiveKeyboard(.keyUp(keyCode: 0), from: source)
        await harness.input.enqueueInput {}.value

        XCTAssertEqual(harness.transport.sentMessages, [
            Data([4, 1, 0, 0, 0, 0, 0xff, 0xeb]),
            Data([4, 1, 0, 0, 0, 0, 0, 97]),
            Data([4, 0, 0, 0, 0, 0, 0xff, 0xeb]),
            Data([4, 0, 0, 0, 0, 0, 0, 97]),
        ])
    }

    func testRemoteSystemCommandsRemainOneShotAndAreNotReleasedWithKeyboardSource() async throws {
        let harness = try makeHarness(sharingType: .standard)
        await harness.input.perform(.missionControl)
        harness.input.releaseKeyboard(from: UUID())
        await harness.input.enqueueInput {}.value

        XCTAssertEqual(harness.transport.sentMessages, [Data([4, 1, 0, 0, 0x10, 0x08, 0xfd, 0x02])])
    }

    private func key(_ code: UInt16, _ symbols: [UInt32], keyboardType: UInt16 = 40) -> AppleKeyboardKey {
        AppleKeyboardKey(keyCode: code, keyboardType: keyboardType, symbols: symbols)
    }

    private func makeHarness(sharingType: ScreenSharingType = .highPerformance) throws -> KeyboardHarness {
        let transport = KeyboardTransport()
        let keys = try AppleRecordKeys(
            key: Data(repeating: 0x11, count: 16), initializationVector: Data(repeating: 0x22, count: 16)
        )
        let session = RFBAuthenticatedSession(
            endpoint: try ConnectionEndpoint("example.local"),
            remoteAddress: try ResolvedRemoteAddress(numericHost: "127.0.0.1", port: 5900),
            sharingType: sharingType, masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(width: 100, height: 100, pixelFormat: Data(repeating: 0, count: 16), name: "Test"),
            transport: transport
        )
        session.install(recordLayer: AppleEncryptedRecordLayer(keys: keys))
        let input = AppleInputController(
            session: session, canvas: AppleCanvas(width: 100, height: 100, tileCount: 1), microseconds: { 123 }
        )
        return KeyboardHarness(session: session, input: input, transport: transport, keys: keys)
    }

    private func assertMessages(_ harness: KeyboardHarness, _ strokes: [(AppleKeyboardKey, Bool)]) throws {
        let expected = AppleEncryptedRecordLayer(keys: harness.keys)
        var messages = [Data]()
        for (key, down) in strokes {
            for symbol in key.symbols {
                messages.append(try expected.encrypt(try expected.encryptKeyEvent(
                    isDown: down, keySymbol: symbol, timestampDelta: messages.isEmpty ? 123 : 0,
                    keyboardType: key.keyboardType, keyCode: key.keyCode
                )))
            }
        }
        XCTAssertEqual(harness.transport.sentMessages, messages)
    }
}

private struct KeyboardHarness {
    let session: RFBAuthenticatedSession
    let input: AppleInputController
    let transport: KeyboardTransport
    let keys: AppleRecordKeys
}

private final class KeyboardTransport: RFBTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var messages = [Data]()
    var sentMessages: [Data] { lock.withLock { messages } }
    func start(timeout: Duration) async throws {}
    func send(_ data: Data) async throws { lock.withLock { messages.append(data) } }
    func receiveExactly(_ length: Int) async throws -> Data { throw RFBNetworkError.connectionClosed }
    func cancel() {}
}
