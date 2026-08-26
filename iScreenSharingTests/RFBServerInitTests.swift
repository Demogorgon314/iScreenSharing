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
}
