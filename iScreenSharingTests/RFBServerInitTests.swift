import XCTest
@testable import iScreenSharing

final class RFBServerInitTests: XCTestCase {
    func testParsesServerInitHeaderAndName() throws {
        let name = Data("deepdream’s Mac mini".utf8)
        var header = Data()
        header.appendUInt16BE(2560)
        header.appendUInt16BE(1440)
        header.append(Data(repeating: 0xab, count: 16))
        header.appendUInt32BE(UInt32(name.count))

        let info = try RFBServerInfo.parse(header: header, nameData: name)

        XCTAssertEqual(info.width, 2560)
        XCTAssertEqual(info.height, 1440)
        XCTAssertEqual(info.pixelFormat, Data(repeating: 0xab, count: 16))
        XCTAssertEqual(info.name, "deepdream’s Mac mini")
        XCTAssertNil(info.serverFlags)
        XCTAssertFalse(info.supportsViewerToHostFileTransfer)
    }

    func testParsesEnhancedCommandBitmapAndRequiresDropAndFileCopyCommands() throws {
        var commands = Data(repeating: 0, count: 16)
        commands[4] = 0xa0
        var name = Data()
        name.appendUInt16BE(0)
        name.appendUInt32BE(0x0102_0304)
        name.append(commands)
        name.append(Data("Remote Mac".utf8))
        var header = Data()
        header.appendUInt16BE(1920)
        header.appendUInt16BE(1080)
        header.append(Data(repeating: 0, count: 16))
        header.appendUInt32BE(UInt32(name.count))

        let info = try RFBServerInfo.parse(header: header, nameData: name)

        XCTAssertEqual(info.name, "Remote Mac")
        XCTAssertEqual(info.serverFlags, 0x0102_0304)
        XCTAssertTrue(info.supportsServerCommand(32))
        XCTAssertTrue(info.supportsServerCommand(34))
        XCTAssertTrue(info.supportsViewerToHostFileTransfer)

        commands[4] = 0x20
        name.replaceSubrange(6..<22, with: commands)
        let policyDisabled = try RFBServerInfo.parse(header: header, nameData: name)
        XCTAssertFalse(policyDisabled.supportsServerCommand(32))
        XCTAssertTrue(policyDisabled.supportsServerCommand(34))
        XCTAssertFalse(policyDisabled.supportsViewerToHostFileTransfer)
    }

    func testClipboardCapabilitiesRequireTheNativeCommandSets() {
        var commands = Data(repeating: 0, count: 16)
        commands[1] = 0x10 // command 11
        commands[3] = 0x01 // command 31
        let manualOnly = makeServerInfo(commands: commands)

        XCTAssertTrue(manualOnly.supportsCopyPaste)
        XCTAssertFalse(manualOnly.supportsSharedPasteboard)

        commands[2] = 0x04 // command 21
        let shared = makeServerInfo(commands: commands)
        XCTAssertTrue(shared.supportsCopyPaste)
        XCTAssertTrue(shared.supportsSharedPasteboard)

        commands[1] = 0
        let missingRequestCommand = makeServerInfo(commands: commands)
        XCTAssertFalse(missingRequestCommand.supportsCopyPaste)
        XCTAssertFalse(missingRequestCommand.supportsSharedPasteboard)
    }

    func testRejectsTruncatedEnhancedServerInitPrefix() {
        let name = Data([0, 0, 1, 2, 3])
        var header = Data()
        header.appendUInt16BE(1920)
        header.appendUInt16BE(1080)
        header.append(Data(repeating: 0, count: 16))
        header.appendUInt32BE(UInt32(name.count))

        XCTAssertThrowsError(try RFBServerInfo.parse(header: header, nameData: name))
    }

    func testRejectsMismatchedNameAndInvalidDimensions() {
        var header = Data(repeating: 0, count: 24)
        header[1] = 1
        header[3] = 1
        header[23] = 2
        XCTAssertThrowsError(try RFBServerInfo.parse(header: header, nameData: Data([1])))

        header[1] = 0
        header[3] = 0
        header[23] = 0
        XCTAssertThrowsError(try RFBServerInfo.parse(header: header, nameData: Data()))
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
}
