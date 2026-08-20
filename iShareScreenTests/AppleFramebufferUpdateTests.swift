import XCTest
@testable import iShareScreen

final class AppleFramebufferUpdateTests: XCTestCase {
    func testExtractsLayoutAfterLengthPrefixedConfigurationRect() throws {
        var message = Data([0, 0, 0, 2])
        message.append(rectangleHeader(encoding: 1010))
        message.appendUInt16BE(3)
        message.append(contentsOf: [1, 2, 3])
        message.append(rectangleHeader(encoding: 0x451))
        let layoutPayload = makeLayoutPayload()
        message.appendUInt16BE(UInt16(layoutPayload.count))
        message.append(layoutPayload)

        let layouts = AppleFramebufferUpdate.displayLayouts(from: message)

        let layout = try XCTUnwrap(layouts.first)
        XCTAssertEqual(layouts.count, 1)
        XCTAssertEqual(layout.canvas, AppleCanvas(width: 2880, height: 1800, tileCount: 1))
        XCTAssertEqual(layout.displays.first?.displayID, 42)
    }

    func testReturnsParsedLayoutsBeforeUnknownOrTruncatedRect() {
        var message = Data([0, 0, 0, 2])
        message.append(rectangleHeader(encoding: 0x451))
        let layoutPayload = makeLayoutPayload()
        message.appendUInt16BE(UInt16(layoutPayload.count))
        message.append(layoutPayload)
        message.append(rectangleHeader(encoding: 6))

        XCTAssertEqual(AppleFramebufferUpdate.displayLayouts(from: message).count, 1)

        var truncated = Data([0, 0, 0, 1])
        truncated.append(rectangleHeader(encoding: 0x451))
        truncated.appendUInt16BE(100)
        XCTAssertTrue(AppleFramebufferUpdate.displayLayouts(from: truncated).isEmpty)
    }

    func testRejectsNonFramebufferAndShortMessages() {
        XCTAssertTrue(AppleFramebufferUpdate.displayLayouts(from: Data()).isEmpty)
        XCTAssertTrue(AppleFramebufferUpdate.displayLayouts(from: Data([1, 0, 0, 0])).isEmpty)
    }

    private func rectangleHeader(encoding: Int32) -> Data {
        var data = Data(repeating: 0, count: 8)
        data.appendInt32BE(encoding)
        return data
    }

    private func makeLayoutPayload() -> Data {
        var payload = Data(repeating: 0, count: 76)
        payload.writeUInt16BE(1, at: 0)
        payload.writeUInt16BE(1440, at: 2)
        payload.writeUInt16BE(900, at: 4)
        payload.writeUInt16BE(2880, at: 6)
        payload.writeUInt16BE(1800, at: 8)
        payload.writeUInt16BE(1, at: 18)
        payload.writeUInt32BE(42, at: 36)
        payload.writeUInt16BE(1800, at: 52)
        payload.writeUInt16BE(2880, at: 54)
        return payload
    }
}
