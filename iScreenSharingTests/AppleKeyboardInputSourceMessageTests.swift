import XCTest
@testable import iScreenSharing

@MainActor
final class AppleKeyboardInputSourceMessageTests: XCTestCase {
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
