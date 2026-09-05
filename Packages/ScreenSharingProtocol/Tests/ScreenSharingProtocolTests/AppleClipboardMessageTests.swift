import Foundation
import XCTest
import ScreenSharingProtocol

final class AppleClipboardMessageTests: XCTestCase {
    func testReassemblesAndDecodesLargeBinaryClipboardWithoutTruncating() throws {
        var state: UInt64 = 27
        let image = Data((0..<100_000).map { _ -> UInt8 in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        })
        let archive = AppleClipboardArchive(items: [AppleClipboardItem(flavors: [
            AppleClipboardFlavor(type: "public.png", aliases: [], value: image),
        ])])
        let message = try AppleClipboardMessage.send(archive: archive, sessionID: 7)
        var reassembler = AppleClipboardReassembler()
        var completed: Data?

        for fragment in AppleClipboardMessage.fragments(of: message) {
            completed = try reassembler.process(fragment)
        }

        let envelope = try AppleClipboardMessage.envelope(from: XCTUnwrap(completed))
        XCTAssertEqual(envelope.sessionID, 7)
        XCTAssertEqual(envelope.archive, archive)
    }

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

    func testClipboardPayloadUsesNativeSyncFlushFraming() throws {
        let message = try AppleClipboardMessage.send(text: "clipboard")
        let compressedSize = try Int(message.uint32BE(at: 12))
        let payload = message.suffix(compressedSize)

        XCTAssertEqual(payload.prefix(2), Data([0x78, 0xda]))
        XCTAssertEqual(payload.suffix(4), Data([0x00, 0x00, 0xff, 0xff]))
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

    func testZeroFlavorItemTerminatesNativeArchive() throws {
        let archive = Data([0, 0, 0, 0, 0xff])
        let compressed = try ZlibCodec.compressSyncFlush(archive)
        var message = Data([0x1f, 0, 0, 0])
        message.appendUInt32BE(1)
        message.appendUInt32BE(UInt32(archive.count))
        message.appendUInt32BE(UInt32(compressed.count))
        message.append(compressed)

        XCTAssertEqual(
            try AppleClipboardMessage.archive(from: message),
            AppleClipboardArchive(items: [])
        )
    }

    func testPreservesNonzeroFlavorReservedFieldInWireArchive() throws {
        let archive = AppleClipboardArchive(items: [
            AppleClipboardItem(flavors: [
                AppleClipboardFlavor(
                    type: "x",
                    aliases: [],
                    value: Data([0xaa]),
                    reserved: 0x1122_3344
                )
            ])
        ])

        let message = try AppleClipboardMessage.send(archive: archive)
        let uncompressedSize = try Int(message.uint32BE(at: 8))
        let compressedSize = try Int(message.uint32BE(at: 12))
        let packed = try ZlibCodec.decompressSyncFlush(
            Data(message.suffix(compressedSize)),
            expectedSize: uncompressedSize
        )

        XCTAssertEqual(
            packed,
            Data([
                0, 0, 0, 1,
                0, 0, 0, 1, 0x78,
                0x11, 0x22, 0x33, 0x44,
                0, 0, 0, 0,
                0, 0, 0, 1, 0xaa,
            ])
        )
        XCTAssertEqual(try AppleClipboardMessage.archive(from: message), archive)
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

    func testSplitsClipboardHeaderAndPayloadLikeNativeEncryptedRecords() {
        let payloadLength = 65_541
        var message = Data(repeating: 0, count: 16)
        message[0] = 0x1f
        message.writeUInt32BE(UInt32(payloadLength), at: 12)
        message.append(Data(repeating: 7, count: payloadLength))

        let fragments = AppleClipboardMessage.fragments(of: message)

        XCTAssertEqual(fragments.map(\.count), [16, 32_768, 32_768, 5])
        XCTAssertEqual(fragments[0], message.prefix(16))
        XCTAssertEqual(fragments.reduce(into: Data()) { $0.append($1) }, message)
    }

    func testSmallClipboardStillEncryptsHeaderAndPayloadSeparately() throws {
        let message = try AppleClipboardMessage.send(text: "clipboard")

        let fragments = AppleClipboardMessage.fragments(of: message)

        XCTAssertEqual(fragments.map(\.count), [16, message.count - 16])
        XCTAssertEqual(fragments[0], message.prefix(16))
        XCTAssertEqual(fragments.reduce(into: Data()) { $0.append($1) }, message)
    }
}

private extension Data {
    func uint32BE(at offset: Int) throws -> UInt32 {
        guard offset >= 0, count >= offset + 4 else { throw ClipboardTestWireError.outOfBounds }
        return UInt32(self[offset]) << 24
            | UInt32(self[offset + 1]) << 16
            | UInt32(self[offset + 2]) << 8
            | UInt32(self[offset + 3])
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func writeUInt32BE(_ value: UInt32, at offset: Int) {
        self[offset] = UInt8(truncatingIfNeeded: value >> 24)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
        self[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
        self[offset + 3] = UInt8(truncatingIfNeeded: value)
    }
}

private enum ClipboardTestWireError: Error {
    case outOfBounds
}
