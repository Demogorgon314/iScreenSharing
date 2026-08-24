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
        XCTAssertEqual(layout.canvas(tileCount: 4), AppleCanvas(width: 2880, height: 1800, tileCount: 4))
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

    func testDecodesAndSelectsCachedCursorImages() throws {
        let raw = Data([3, 2, 1, 255, 7, 6, 5, 255, 9, 10])
        let compressed = try ZlibCodec.compress(raw)
        var message = Data([0, 0, 0, 2])
        message.append(cursorHeader(hotspotX: 1, hotspotY: 0, width: 2, height: 1))
        message.appendUInt32BE(42)
        message.appendUInt32BE(UInt32(compressed.count))
        message.append(compressed)
        message.append(cursorHeader(hotspotX: 0, hotspotY: 0, width: 0, height: 0))
        message.appendUInt32BE(42)
        message.appendUInt32BE(0)

        let updates = AppleFramebufferUpdate.cursorUpdates(from: message)

        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(
            updates[0],
            .store(
                id: 42,
                image: AppleCursorImage(
                    width: 2,
                    height: 1,
                    hotspotX: 1,
                    hotspotY: 0,
                    rgba: Data([1, 2, 3, 9, 5, 6, 7, 10])
                )
            )
        )
        XCTAssertEqual(updates[1], .select(id: 42))
    }

    func testRejectsMalformedCursorWithoutDiscardingEarlierUpdates() throws {
        var message = Data([0, 0, 0, 2])
        message.append(cursorHeader(hotspotX: 0, hotspotY: 0, width: 0, height: 0))
        message.appendUInt32BE(7)
        message.appendUInt32BE(0)
        message.append(cursorHeader(hotspotX: 2, hotspotY: 0, width: 1, height: 1))
        let compressed = try ZlibCodec.compress(Data(repeating: 0, count: 5))
        message.appendUInt32BE(8)
        message.appendUInt32BE(UInt32(compressed.count))
        message.append(compressed)

        XCTAssertEqual(AppleFramebufferUpdate.cursorUpdates(from: message), [.select(id: 7)])

        message.removeLast()
        XCTAssertEqual(AppleFramebufferUpdate.cursorUpdates(from: message), [.select(id: 7)])
    }

    func testParsesVersionOneVendorKeySymbolCapabilities() {
        var message = Data([0, 0, 0, 1])
        message.append(rectangleHeader(encoding: 1107))
        message.appendUInt16BE(20)
        message.appendUInt16BE(1)
        message.appendUInt16BE(4)
        AppleRemoteSystemCommand.allCases.forEach { message.appendUInt32BE($0.rawValue) }

        XCTAssertEqual(
            AppleFramebufferUpdate.contents(from: message).vendorKeySymbols,
            [Set(AppleRemoteSystemCommand.allCases.map(\.rawValue))]
        )
    }

    func testRejectsUnsupportedOrTruncatedVendorKeySymbolCapabilities() {
        var unsupported = Data([0, 0, 0, 1])
        unsupported.append(rectangleHeader(encoding: 1107))
        unsupported.appendUInt16BE(4)
        unsupported.appendUInt16BE(2)
        unsupported.appendUInt16BE(0)
        XCTAssertTrue(AppleFramebufferUpdate.contents(from: unsupported).vendorKeySymbols.isEmpty)

        var truncated = Data([0, 0, 0, 1])
        truncated.append(rectangleHeader(encoding: 1107))
        truncated.appendUInt16BE(8)
        truncated.appendUInt16BE(1)
        truncated.appendUInt16BE(2)
        truncated.appendUInt32BE(AppleRemoteSystemCommand.desktop.rawValue)
        XCTAssertTrue(AppleFramebufferUpdate.contents(from: truncated).vendorKeySymbols.isEmpty)
    }

    func testParsesKeyboardInputSourceEncoding() {
        var message = Data([0, 0, 0, 1])
        message.append(rectangleHeader(encoding: 1109))
        message.appendUInt16BE(10)
        message.append(contentsOf: [0, 1, 0, 0, 0, 1, 0, 2])
        message.append(Data("US".utf8))

        XCTAssertEqual(
            AppleFramebufferUpdate.contents(from: message).keyboardInputSources,
            [AppleKeyboardInputSourceState(field: 1, isSecureInput: true, identifier: "US")]
        )
    }

    func testParsesVersionTwoDeviceInfoEncoding() throws {
        var payload = Data()
        payload.appendUInt16BE(2)
        payload.appendUInt32BE(1)
        payload.append(contentsOf: [0x33, 0x22, 0x11, 0])
        payload.appendUInt16BE(9)
        payload.appendUInt16BE(2)
        payload.appendUInt16BE(2)
        payload.append(Data("Mac16,10\0".utf8))
        payload.append(Data("0\0".utf8))
        payload.append(Data("1\0".utf8))
        payload.appendUInt32BE(7)

        var message = Data([0, 0, 0, 1])
        message.append(rectangleHeader(encoding: 1110))
        message.appendUInt16BE(UInt16(payload.count))
        message.append(payload)

        XCTAssertEqual(
            AppleFramebufferUpdate.contents(from: message).deviceInfos,
            [AppleRemoteDeviceInfo(
                modelIdentifier: "Mac16,10",
                deviceColor: "0",
                enclosureColor: "1",
                enclosureRGBColorComponents: 0x0011_2233,
                housingColor: 7,
                flags: 1
            )]
        )
    }

    func testRejectsMalformedDeviceInfoEncoding() {
        var missingTerminator = Data(repeating: 0, count: 16)
        missingTerminator.writeUInt16BE(2, at: 0)
        missingTerminator.writeUInt16BE(3, at: 10)
        missingTerminator.writeUInt16BE(1, at: 12)
        missingTerminator.writeUInt16BE(1, at: 14)
        missingTerminator.append(Data("Mac".utf8))
        missingTerminator.append(contentsOf: [0, 0, 0, 0, 0, 0])

        var message = Data([0, 0, 0, 1])
        message.append(rectangleHeader(encoding: 1110))
        message.appendUInt16BE(UInt16(missingTerminator.count))
        message.append(missingTerminator)

        XCTAssertTrue(AppleFramebufferUpdate.contents(from: message).deviceInfos.isEmpty)

        var truncated = message
        truncated.removeLast(2)
        XCTAssertTrue(AppleFramebufferUpdate.contents(from: truncated).deviceInfos.isEmpty)
    }

    private func rectangleHeader(encoding: Int32) -> Data {
        var data = Data(repeating: 0, count: 8)
        data.appendInt32BE(encoding)
        return data
    }

    private func cursorHeader(
        hotspotX: UInt16,
        hotspotY: UInt16,
        width: UInt16,
        height: UInt16
    ) -> Data {
        var data = Data()
        data.appendUInt16BE(hotspotX)
        data.appendUInt16BE(hotspotY)
        data.appendUInt16BE(width)
        data.appendUInt16BE(height)
        data.appendInt32BE(0x450)
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
