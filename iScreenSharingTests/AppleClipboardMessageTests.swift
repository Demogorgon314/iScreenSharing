import XCTest
@testable import iScreenSharing

final class AppleClipboardMessageTests: XCTestCase {
    func testBuildsEnableAndFetchMessages() {
        XCTAssertEqual(AppleClipboardMessage.enable, Data([0x15, 0, 0, 1, 0, 0, 0, 0]))
        XCTAssertEqual(AppleClipboardMessage.disable, Data([0x15, 0, 0, 2, 0, 0, 0, 0]))
        XCTAssertEqual(AppleClipboardMessage.fetch, Data([0x0b, 0, 0, 0, 0, 0, 0, 0]))
        XCTAssertEqual(
            AppleClipboardMessage.request(promises: true, sessionID: 0x0102_0304),
            Data([0x0b, 1, 0, 0, 1, 2, 3, 4])
        )
    }

    func testRoundTripsUnicodeTextArchive() throws {
        let message = try AppleClipboardMessage.send(text: "Hello, 世界 👋")
        XCTAssertEqual(message[0], 0x1f)
        XCTAssertEqual(try AppleClipboardMessage.text(from: message), "Hello, 世界 👋")
    }

    func testRoundTripsMultipleItemsFlavorsAndAliases() throws {
        let archive = AppleClipboardArchive(items: [
            AppleClipboardItem(flavors: [
                AppleClipboardFlavor(
                    type: "public.rtf",
                    aliases: [AppleClipboardTypeAlias(
                        tagClass: "public.mime-type",
                        preferredTag: "text/rtf"
                    )],
                    value: Data("{\\rtf1 Hello}".utf8)
                ),
                AppleClipboardFlavor(
                    type: AppleClipboardMessage.textType,
                    aliases: [],
                    value: Data("Hello".utf8)
                )
            ]),
            AppleClipboardItem(flavors: [
                AppleClipboardFlavor(
                    type: "public.png",
                    aliases: [],
                    value: Data([0x89, 0x50, 0x4e, 0x47])
                )
            ])
        ])

        let message = try AppleClipboardMessage.send(
            archive: archive,
            promises: false,
            sessionID: 42
        )
        let envelope = try AppleClipboardMessage.envelope(from: message)

        XCTAssertEqual(envelope.sessionID, 42)
        XCTAssertFalse(envelope.containsPromises)
        XCTAssertEqual(envelope.archive, archive)
        XCTAssertEqual(envelope.archive.preferredText, "Hello")
    }

    func testPromiseArchivePreservesMetadataAndOmitsValues() throws {
        let archive = AppleClipboardArchive(items: [
            AppleClipboardItem(flavors: [
                AppleClipboardFlavor(type: "public.png", aliases: [], value: Data([1, 2, 3]))
            ])
        ])

        let envelope = try AppleClipboardMessage.envelope(
            from: AppleClipboardMessage.send(archive: archive, promises: true)
        )

        XCTAssertTrue(envelope.containsPromises)
        XCTAssertEqual(envelope.archive.items[0].flavors[0].type, "public.png")
        XCTAssertTrue(envelope.archive.items[0].flavors[0].value.isEmpty)
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

    func testRejectsInvalidUTF8ClipboardMetadata() throws {
        var archive = Data()
        archive.appendUInt32BE(1)
        archive.appendUInt32BE(1)
        archive.append(0xff)
        archive.appendUInt32BE(0)
        archive.appendUInt32BE(0)
        archive.appendUInt32BE(0)
        let compressed = try ZlibCodec.compress(archive)
        var message = Data([0x1f, 0, 0, 0])
        message.appendUInt32BE(1)
        message.appendUInt32BE(UInt32(archive.count))
        message.appendUInt32BE(UInt32(compressed.count))
        message.append(compressed)

        XCTAssertThrowsError(try AppleClipboardMessage.archive(from: message)) {
            XCTAssertEqual($0 as? AppleClipboardError, .invalidMessage)
        }
    }

    func testSplitsLargeClipboardMessageIntoRecordSafeFragments() {
        let message = Data(repeating: 7, count: 130_000)
        let fragments = AppleClipboardMessage.fragments(of: message)
        XCTAssertEqual(fragments.map(\.count), [60_000, 60_000, 10_000])
        XCTAssertEqual(fragments.reduce(into: Data()) { $0.append($1) }, message)
    }
}
