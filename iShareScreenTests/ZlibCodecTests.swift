import XCTest
@testable import iShareScreen

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
}
