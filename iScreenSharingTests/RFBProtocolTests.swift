import XCTest
@testable import iScreenSharing

final class RFBProtocolTests: XCTestCase {
    func testParsesAppleVersionBanner() throws {
        let version = try RFBProtocol.parseVersion(Data("RFB 003.889\n".utf8))

        XCTAssertEqual(version, RFBVersion(major: 3, minor: 889))
    }

    func testRejectsMalformedVersionBanners() {
        XCTAssertThrowsError(try RFBProtocol.parseVersion(Data("RFB 3.889\n".utf8)))
        XCTAssertThrowsError(try RFBProtocol.parseVersion(Data("HTTP/1.1 OK\n".utf8)))
        XCTAssertThrowsError(try RFBProtocol.parseVersion(Data(repeating: 0xff, count: 12)))
    }

    func testParsesSecurityTypesWithoutDiscardingUnknownValues() throws {
        let types = try RFBProtocol.parseSecurityTypes(
            Data([30, 33, 35, 36, 250]),
            expectedCount: 5
        )

        XCTAssertEqual(types, [.appleDiffieHellman, .appleRSA, .appleKerberos, .appleSRP, .init(rawValue: 250)])
    }

    func testRejectsZeroOrMismatchedSecurityTypeCount() {
        XCTAssertThrowsError(try RFBProtocol.parseSecurityTypeCount(Data([0])))
        XCTAssertThrowsError(try RFBProtocol.parseSecurityTypeCount(Data()))
        XCTAssertThrowsError(try RFBProtocol.parseSecurityTypes(Data([33]), expectedCount: 2))
    }
}

