import CryptoKit
import XCTest
@testable import iShareScreen

final class AppleDisplayConfigurationTests: XCTestCase {
    func testBuildsVirtualDisplayMessageMatchingIndependentReference() throws {
        let message = try AppleDisplayConfiguration.message(width: 1440, height: 900)

        XCTAssertEqual(message.count, 308)
        XCTAssertEqual(message[0], 0x1d)
        XCTAssertEqual(try message.uint16BE(at: 2), 304)
        XCTAssertEqual(try message.uint16BE(at: 4), 1)
        XCTAssertEqual(try message.uint16BE(at: 6), 1)
        XCTAssertEqual(try message.uint16BE(at: 12), 0x128)
        XCTAssertEqual(
            SHA256.hash(data: message).hex,
            "ed51d8047aeed21994cfc296cf0dad9eba67bb4c5eb5acac37d865666bc901a3"
        )
    }

    func testBuildsHDRModeAndTruncatesLongDisplayName() throws {
        let message = try AppleDisplayConfiguration.message(
            width: 1920,
            height: 1080,
            backingScale: 1,
            hdr: true,
            displayName: String(repeating: "a", count: 200)
        )
        let descriptorOffset = 12
        let firstModeOffset = descriptorOffset + 0x9c

        XCTAssertEqual(message[descriptorOffset + 2..<descriptorOffset + 121], Data(repeating: 0x61, count: 119))
        XCTAssertEqual(message[descriptorOffset + 121], 0)
        XCTAssertEqual(try message.uint32BE(at: firstModeOffset), 1920)
        XCTAssertEqual(try message.uint32BE(at: firstModeOffset + 4), 1080)
        XCTAssertEqual(try message.uint32BE(at: firstModeOffset + 24), 1)
    }

    func testRejectsInvalidGeometryAndScale() {
        XCTAssertThrowsError(try AppleDisplayConfiguration.message(width: 0, height: 900)) {
            XCTAssertEqual($0 as? AppleDisplayConfigurationError, .invalidDimensions)
        }
        XCTAssertThrowsError(try AppleDisplayConfiguration.message(width: 1440, height: 900, backingScale: .nan)) {
            XCTAssertEqual($0 as? AppleDisplayConfigurationError, .invalidBackingScale)
        }
    }

    func testParsesAppleDisplayLayout() throws {
        var payload = Data(repeating: 0, count: 76)
        payload.writeUInt16BE(1, at: 0)
        payload.writeUInt16BE(1440, at: 2)
        payload.writeUInt16BE(900, at: 4)
        payload.writeUInt16BE(2880, at: 6)
        payload.writeUInt16BE(1800, at: 8)
        payload.writeUInt16BE(1, at: 18)
        payload.writeUInt32BE(42, at: 36)
        payload.writeUInt16BE(20, at: 48)
        payload.writeUInt16BE(10, at: 50)
        payload.writeUInt16BE(1820, at: 52)
        payload.writeUInt16BE(2890, at: 54)

        let layout = try XCTUnwrap(AppleDisplayConfiguration.layout(from: payload))

        XCTAssertEqual(layout.scaledWidth, 1440)
        XCTAssertEqual(layout.scaledHeight, 900)
        XCTAssertEqual(layout.canvas(tileCount: 4), AppleCanvas(width: 2880, height: 1800, tileCount: 4))
        XCTAssertEqual(layout.displays, [
            AppleDisplayRect(displayID: 42, x: 10, y: 20, width: 2880, height: 1800),
        ])
    }

    func testRejectsTruncatedAndDegenerateDisplayLayouts() {
        XCTAssertNil(AppleDisplayConfiguration.layout(from: Data(repeating: 0, count: 19)))

        var truncated = Data(repeating: 0, count: 20)
        truncated.writeUInt16BE(1, at: 18)
        XCTAssertNil(AppleDisplayConfiguration.layout(from: truncated))

        var degenerate = Data(repeating: 0, count: 76)
        degenerate.writeUInt16BE(1, at: 18)
        XCTAssertNil(AppleDisplayConfiguration.layout(from: degenerate))
    }
}

private extension SHA256.Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
