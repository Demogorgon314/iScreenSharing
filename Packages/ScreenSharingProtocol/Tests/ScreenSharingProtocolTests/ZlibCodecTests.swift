import Foundation
import XCTest
import ScreenSharingProtocol

final class ZlibCodecTests: XCTestCase {
    func testDecodesIndependentSyncFlushStream() throws {
        let compressed = Data([
            0x78, 0x9c, 0x2a, 0xae, 0xcc, 0x4b, 0x56, 0x48, 0xcb,
            0x29, 0x2d, 0xce, 0x50, 0x28, 0x48, 0xac, 0xcc, 0xc9,
            0x4f, 0x4c, 0x01, 0x00, 0x00, 0x00, 0xff, 0xff,
        ])
        XCTAssertEqual(
            try ZlibCodec.decompressSyncFlush(compressed, expectedSize: 18),
            Data("sync flush payload".utf8)
        )
    }

    func testRoundTripsCompleteStream() throws {
        let input = Data(repeating: 0x5a, count: 8_192)
        XCTAssertEqual(try ZlibCodec.decompress(ZlibCodec.compress(input)), input)
    }

    func testMaintainsDictionaryAcrossSyncFlushSegments() throws {
        let first = Data(String(repeating: "native-file-copy-", count: 4_096).utf8)
        let second = Data(String(repeating: "native-file-copy-", count: 4_096).utf8)
        let compressor = try ZlibSyncFlushCompressor()
        let decompressor = try ZlibSyncFlushDecompressor()

        let firstCompressed = try compressor.compress(first)
        let secondCompressed = try compressor.compress(second)

        XCTAssertEqual(firstCompressed.prefix(2), Data([0x78, 0xda]))
        XCTAssertNotEqual(secondCompressed.prefix(2), Data([0x78, 0xda]))
        XCTAssertEqual(firstCompressed.suffix(4), Data([0, 0, 0xff, 0xff]))
        XCTAssertEqual(secondCompressed.suffix(4), Data([0, 0, 0xff, 0xff]))
        XCTAssertEqual(
            try decompressor.decompress(firstCompressed, expectedSize: first.count),
            first
        )
        XCTAssertEqual(
            try decompressor.decompress(secondCompressed, expectedSize: second.count),
            second
        )
        XCTAssertLessThan(secondCompressed.count, firstCompressed.count)
    }

    func testStreamingDecoderRejectsWrongExpectedSize() throws {
        let input = Data(repeating: 0x41, count: 1_024)
        let compressed = try ZlibSyncFlushCompressor().compress(input)
        let decompressor = try ZlibSyncFlushDecompressor()

        XCTAssertThrowsError(try decompressor.decompress(
            compressed,
            expectedSize: input.count - 1
        )) {
            XCTAssertEqual($0 as? ZlibCodecError, .outputTooLarge)
        }
    }
}
