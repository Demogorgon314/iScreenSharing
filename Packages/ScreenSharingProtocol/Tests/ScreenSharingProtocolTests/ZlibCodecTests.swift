import Foundation
import XCTest
import ScreenSharingProtocol

final class ZlibCodecTests: XCTestCase {
    func testSyncFlushDrainsBufferedOutputAcrossChunkBoundaries() throws {
        var state: UInt64 = 27
        let random = Data((0..<262_144).map { _ -> UInt8 in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        })
        for size in [65_535, 65_536, 65_537, 100_030, 131_072, 262_144] {
            for input in [Data(random.prefix(size)), Data(repeating: 0x5a, count: size)] {
                let compressed = try ZlibCodec.compressSyncFlush(input)

                let decoded = try ZlibCodec.decompressSyncFlush(
                    compressed,
                    expectedSize: input.count,
                    maximumOutputLength: input.count
                )

                XCTAssertEqual(decoded, input, "Uncompressed bytes: \(size)")
            }
        }
    }

    func testSyncFlushDecoderAcceptsCompletedAndEmptyStreams() throws {
        let input = Data(repeating: 0x5a, count: 131_073)
        XCTAssertEqual(
            try ZlibCodec.decompressSyncFlush(ZlibCodec.compress(input), expectedSize: input.count),
            input
        )
        // Independent zlib vectors for an empty sync-flush segment and a
        // completed empty stream, respectively.
        for emptyStream in [
            Data([0x78, 0x9c, 0, 0, 0, 0xff, 0xff]),
            Data([0x78, 0x9c, 3, 0, 0, 0, 0, 1]),
        ] {
            XCTAssertEqual(
                try ZlibCodec.decompressSyncFlush(emptyStream, expectedSize: 0, maximumOutputLength: 0),
                Data()
            )
        }
    }

    func testSyncFlushRejectsOutputBeyondLimitWhileDraining() throws {
        let compressed = try ZlibCodec.compressSyncFlush(Data(repeating: 0x41, count: 131_073))

        XCTAssertThrowsError(try ZlibCodec.decompressSyncFlush(
            compressed,
            expectedSize: 131_072,
            maximumOutputLength: 131_072
        )) {
            XCTAssertEqual($0 as? ZlibCodecError, .outputTooLarge)
        }
    }

    func testSyncFlushRejectsMalformedAndTruncatedInput() throws {
        let compressed = try ZlibCodec.compressSyncFlush(Data(repeating: 0x41, count: 100_000))
        for malformed in [
            Data(),
            Data([0x78]),
            Data([0, 0]),
            Data([0x78, 0x9c, 0x07]), // Reserved deflate block type.
            Data(compressed.prefix(compressed.count / 2)),
        ] {
            XCTAssertThrowsError(try ZlibCodec.decompressSyncFlush(malformed, expectedSize: 100_000)) {
                XCTAssertEqual($0 as? ZlibCodecError, .invalidStream)
            }
        }
    }

    func testSyncFlushRejectsIncorrectDeclaredLength() throws {
        let compressed = try ZlibCodec.compressSyncFlush(Data(repeating: 0x41, count: 100))
        for size in [-1, 0, 99, 101, ZlibCodec.defaultMaximumOutputLength + 1] {
            XCTAssertThrowsError(try ZlibCodec.decompressSyncFlush(compressed, expectedSize: size)) {
                XCTAssertEqual($0 as? ZlibCodecError, .invalidStream)
            }
        }
    }

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
