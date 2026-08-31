import Foundation
import XCTest
import ScreenSharingProtocol

final class RFBServerInitTests: XCTestCase {
    func testParsesServerInitHeaderAndName() throws {
        let name = Data("deepdream’s Mac mini".utf8)
        let header = makeHeader(width: 2560, height: 1440, nameLength: name.count, pixelByte: 0xab)

        let info = try RFBServerInfo.parse(header: header, nameData: name)

        XCTAssertEqual(info.width, 2560)
        XCTAssertEqual(info.height, 1440)
        XCTAssertEqual(info.pixelFormat, Data(repeating: 0xab, count: 16))
        XCTAssertEqual(info.name, "deepdream’s Mac mini")
        XCTAssertNil(info.serverFlags)
        XCTAssertFalse(info.supportsViewerToHostFileTransfer)
    }

    func testParsesEnhancedCommandBitmapAndRequiresBothFileTransferCommands() throws {
        var commands = Data(repeating: 0, count: 16)
        commands[4] = 0xa0
        var name = Data([0, 0, 1, 2, 3, 4])
        name.append(commands)
        name.append(Data("Remote Mac".utf8))
        let header = makeHeader(width: 1920, height: 1080, nameLength: name.count)

        let info = try RFBServerInfo.parse(header: header, nameData: name)

        XCTAssertEqual(info.name, "Remote Mac")
        XCTAssertEqual(info.serverFlags, 0x0102_0304)
        XCTAssertTrue(info.supportsServerCommand(32))
        XCTAssertTrue(info.supportsServerCommand(34))
        XCTAssertTrue(info.supportsViewerToHostFileTransfer)

        commands[4] = 0x20
        name.replaceSubrange(6..<22, with: commands)
        let missingDropCommand = try RFBServerInfo.parse(header: header, nameData: name)
        XCTAssertFalse(missingDropCommand.supportsServerCommand(32))
        XCTAssertTrue(missingDropCommand.supportsServerCommand(34))
        XCTAssertFalse(missingDropCommand.supportsViewerToHostFileTransfer)
    }

    func testClipboardCapabilitiesRequireTheNativeCommandSets() {
        var commands = Data(repeating: 0, count: 16)
        commands[1] = 0x10
        commands[3] = 0x01
        let manualOnly = makeServerInfo(commands: commands)

        XCTAssertTrue(manualOnly.supportsCopyPaste)
        XCTAssertFalse(manualOnly.supportsSharedPasteboard)

        commands[2] = 0x04
        let shared = makeServerInfo(commands: commands)
        XCTAssertTrue(shared.supportsCopyPaste)
        XCTAssertTrue(shared.supportsSharedPasteboard)

        commands[1] = 0
        let missingRequestCommand = makeServerInfo(commands: commands)
        XCTAssertFalse(missingRequestCommand.supportsCopyPaste)
        XCTAssertFalse(missingRequestCommand.supportsSharedPasteboard)
    }

    func testRejectsMalformedServerInitInputsWithSpecificErrors() {
        let truncatedEnhancedName = Data([0, 0, 1, 2, 3])
        let truncatedHeader = makeHeader(
            width: 1920,
            height: 1080,
            nameLength: truncatedEnhancedName.count
        )
        XCTAssertThrowsError(
            try RFBServerInfo.parse(header: truncatedHeader, nameData: truncatedEnhancedName)
        ) { error in
            XCTAssertEqual(error as? RFBServerInitError, .invalidMessage)
        }

        let mismatchedHeader = makeHeader(width: 1, height: 1, nameLength: 2)
        XCTAssertThrowsError(
            try RFBServerInfo.parse(header: mismatchedHeader, nameData: Data([1]))
        ) { error in
            XCTAssertEqual(error as? RFBServerInitError, .invalidMessage)
        }

        let zeroSizeHeader = makeHeader(width: 0, height: 0, nameLength: 0)
        XCTAssertThrowsError(
            try RFBServerInfo.parse(header: zeroSizeHeader, nameData: Data())
        ) { error in
            XCTAssertEqual(error as? RFBServerInitError, .invalidDimensions)
        }

        let invalidUTF8 = Data([0xff])
        let invalidNameHeader = makeHeader(width: 1, height: 1, nameLength: invalidUTF8.count)
        XCTAssertThrowsError(
            try RFBServerInfo.parse(header: invalidNameHeader, nameData: invalidUTF8)
        ) { error in
            XCTAssertEqual(error as? RFBServerInitError, .invalidMessage)
        }
    }

    func testAcceptsNativeMaximumFramebufferDimensions() throws {
        let maximum = RFBServerInfo.maximumFramebufferDimension
        let header = makeHeader(width: maximum, height: maximum, nameLength: 0)

        let info = try RFBServerInfo.parse(header: header, nameData: Data())

        XCTAssertEqual(info.width, maximum)
        XCTAssertEqual(info.height, maximum)
    }

    func testRejectsFramebufferDimensionsAboveNativeMaximum() {
        let oversized = RFBServerInfo.maximumFramebufferDimension + 1
        for (width, height) in [
            (oversized, 1),
            (1, oversized),
            (UInt16.max, UInt16.max),
        ] {
            let header = makeHeader(width: width, height: height, nameLength: 0)

            XCTAssertThrowsError(
                try RFBServerInfo.parse(header: header, nameData: Data())
            ) { error in
                XCTAssertEqual(error as? RFBServerInitError, .invalidDimensions)
            }
        }
    }

    func testCommandCapabilitiesRejectMalformedBitmap() {
        let info = makeServerInfo(commands: Data(repeating: 0xff, count: 15))

        XCTAssertFalse(info.supportsServerCommand(0))
        XCTAssertFalse(info.supportsServerCommand(.max))
    }

    private func makeServerInfo(commands: Data) -> RFBServerInfo {
        RFBServerInfo(
            width: 1920,
            height: 1080,
            pixelFormat: Data(repeating: 0, count: 16),
            name: "Remote Mac",
            commandBitmap: commands
        )
    }

    private func makeHeader(
        width: UInt16,
        height: UInt16,
        nameLength: Int,
        pixelByte: UInt8 = 0
    ) -> Data {
        var header = Data([
            UInt8(truncatingIfNeeded: width >> 8),
            UInt8(truncatingIfNeeded: width),
            UInt8(truncatingIfNeeded: height >> 8),
            UInt8(truncatingIfNeeded: height),
        ])
        header.append(Data(repeating: pixelByte, count: 16))
        let length = UInt32(nameLength)
        header.append(contentsOf: [
            UInt8(truncatingIfNeeded: length >> 24),
            UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length),
        ])
        return header
    }
}
