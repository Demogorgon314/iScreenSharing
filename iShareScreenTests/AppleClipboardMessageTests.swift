import XCTest
@testable import iShareScreen

final class AppleClipboardMessageTests: XCTestCase {
    func testBuildsEnableAndFetchMessages() {
        XCTAssertEqual(AppleClipboardMessage.enable, Data([0x15, 0, 0, 1, 0, 0, 0, 0]))
        XCTAssertEqual(AppleClipboardMessage.fetch, Data([0x0b, 0, 0, 0, 0, 0, 0, 0]))
    }

    func testRoundTripsUnicodeTextArchive() throws {
        let message = try AppleClipboardMessage.send(text: "Hello, 世界 👋")
        XCTAssertEqual(message[0], 0x1f)
        XCTAssertEqual(try AppleClipboardMessage.text(from: message), "Hello, 世界 👋")
    }

    func testReassemblesClipboardAcrossEncryptedRecordFragments() throws {
        let message = try AppleClipboardMessage.send(text: String(repeating: "clip", count: 1_000))
        var reassembler = AppleClipboardReassembler()

        XCTAssertNil(try reassembler.process(message.prefix(20)))
        XCTAssertTrue(reassembler.isInProgress)
        let completed = try XCTUnwrap(try reassembler.process(message.dropFirst(20)))
        XCTAssertEqual(completed, message)
    }

    func testRejectsOversizedDeclaredPayload() throws {
        var message = Data(repeating: 0, count: 16)
        message[0] = 0x1f
        message.writeUInt32BE(UInt32(AppleClipboardMessage.maximumPayloadLength + 1), at: 12)
        XCTAssertThrowsError(try AppleClipboardMessage.text(from: message))
    }

    func testSplitsLargeClipboardMessageIntoRecordSafeFragments() {
        let message = Data(repeating: 7, count: 130_000)
        let fragments = AppleClipboardMessage.fragments(of: message)
        XCTAssertEqual(fragments.map(\.count), [60_000, 60_000, 10_000])
        XCTAssertEqual(fragments.reduce(into: Data()) { $0.append($1) }, message)
    }
}
