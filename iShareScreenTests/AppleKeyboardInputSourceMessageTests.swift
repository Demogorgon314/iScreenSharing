import XCTest
@testable import iShareScreen

@MainActor
final class AppleKeyboardInputSourceMessageTests: XCTestCase {
    func testBuildsNativeShareAndDisableMessagesWithoutNullTerminator() throws {
        XCTAssertEqual(
            try AppleKeyboardInputSourceMessage.share(identifier: "com.apple.keylayout.US"),
            Data([0x1a, 0x00, 0x00, 0x1a, 0x00, 0x01, 0x00, 0x16])
                + Data("com.apple.keylayout.US".utf8)
        )
        XCTAssertEqual(
            try AppleKeyboardInputSourceMessage.share(identifier: nil),
            Data([0x1a, 0x00, 0x00, 0x04, 0x00, 0x01, 0x00, 0x00])
        )
    }

    func testParsesRemoteInputSourceAndSecureInputFlag() {
        var payload = Data([0x00, 0x01, 0, 0, 0, 1, 0, 2])
        payload.append(Data("US".utf8))
        XCTAssertEqual(
            AppleKeyboardInputSourceMessage.state(from: payload),
            AppleKeyboardInputSourceState(field: 1, isSecureInput: true, identifier: "US")
        )
    }

    func testRejectsEmptyAndTruncatedRemoteIdentifiers() {
        XCTAssertNil(AppleKeyboardInputSourceMessage.state(from: Data(repeating: 0, count: 8)))
        XCTAssertNil(AppleKeyboardInputSourceMessage.state(from: Data([0, 1, 0, 0, 0, 0, 0, 2, 0x55])))
    }

    func testServiceDefaultsOffAndUsesRemoteStateAsCapabilityEvidence() async throws {
        let recorder = KeyboardSourceRecorder()
        let service = AppleKeyboardInputSourceService(
            currentIdentifier: { "com.apple.keylayout.US" },
            send: { message in await recorder.record(message) },
            updateUsesSameInputSource: { same in await recorder.recordRelationship(same) }
        )

        service.start()
        await Task.yield()
        XCTAssertFalse(service.isSharingEnabled)
        XCTAssertFalse(service.isSupported)
        let initialMessageCount = await recorder.messageCount()
        XCTAssertEqual(initialMessageCount, 0)

        service.receive(AppleKeyboardInputSourceState(
            field: 1,
            isSecureInput: true,
            identifier: "com.apple.keylayout.US"
        ))
        service.setSharingEnabled(true)
        for _ in 0..<100 {
            if await recorder.lastMessage() != nil { break }
            await Task.yield()
        }

        XCTAssertTrue(service.isSupported)
        XCTAssertTrue(service.serverUsesSecureInput)
        let lastMessage = await recorder.lastMessage()
        let lastRelationship = await recorder.lastRelationship()
        XCTAssertEqual(lastMessage, try AppleKeyboardInputSourceMessage.share(
            identifier: "com.apple.keylayout.US"
        ))
        XCTAssertEqual(lastRelationship, true)
        service.close()
    }

    func testRestoredSharingWaitsForServerCapabilityBeforeSending() async throws {
        let recorder = KeyboardSourceRecorder()
        let service = AppleKeyboardInputSourceService(
            isSharingEnabled: true,
            currentIdentifier: { "com.apple.keylayout.US" },
            send: { message in await recorder.record(message) }
        )

        service.start()
        await Task.yield()
        let messageCountBeforeCapability = await recorder.messageCount()
        XCTAssertEqual(messageCountBeforeCapability, 0)

        service.receive(AppleKeyboardInputSourceState(
            field: 1,
            isSecureInput: false,
            identifier: "com.apple.keylayout.US"
        ))
        for _ in 0..<100 {
            if await recorder.lastMessage() != nil { break }
            await Task.yield()
        }

        let lastMessage = await recorder.lastMessage()
        XCTAssertEqual(
            lastMessage,
            try AppleKeyboardInputSourceMessage.share(identifier: "com.apple.keylayout.US")
        )
        service.close()
    }
}

private actor KeyboardSourceRecorder {
    private var messages = [Data]()
    private var relationships = [Bool]()

    func record(_ message: Data) { messages.append(message) }
    func recordRelationship(_ value: Bool) { relationships.append(value) }
    func messageCount() -> Int { messages.count }
    func lastMessage() -> Data? { messages.last }
    func lastRelationship() -> Bool? { relationships.last }
}
