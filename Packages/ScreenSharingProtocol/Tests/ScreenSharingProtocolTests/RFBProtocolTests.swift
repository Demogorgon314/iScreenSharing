import Foundation
import XCTest
import ScreenSharingProtocol

final class RFBProtocolTests: XCTestCase {
    func testParsesAppleVersionBanner() throws {
        let version = try RFBProtocol.parseVersion(Data("RFB 003.889\n".utf8))

        XCTAssertEqual(version, RFBVersion(major: 3, minor: 889))
    }

    func testRejectsMalformedVersionBanners() {
        let malformed = [
            Data("RFB 3.889\n".utf8),
            Data("HTTP/1.1 OK\n".utf8),
            Data(repeating: 0xff, count: 12),
            Data("RFB 003.88\n".utf8),
            Data("RFB 003.889X\n".utf8),
            Data("RFB 00A.889\n".utf8),
        ]

        for banner in malformed {
            XCTAssertThrowsError(try RFBProtocol.parseVersion(banner)) { error in
                XCTAssertEqual(error as? RFBProtocolError, .invalidVersionBanner)
            }
        }
    }

    func testParsesSecurityTypesWithoutDiscardingUnknownValues() throws {
        let types = try RFBProtocol.parseSecurityTypes(
            Data([30, 33, 35, 36, 250]),
            expectedCount: 5
        )

        XCTAssertEqual(types, [.appleDiffieHellman, .appleRSA, .appleKerberos, .appleSRP, .init(rawValue: 250)])
    }

    func testRejectsZeroOrMismatchedSecurityTypeCount() {
        XCTAssertThrowsError(try RFBProtocol.parseSecurityTypeCount(Data([0]))) { error in
            XCTAssertEqual(error as? RFBProtocolError, .serverRejectedConnection)
        }
        XCTAssertThrowsError(try RFBProtocol.parseSecurityTypeCount(Data())) { error in
            XCTAssertEqual(error as? RFBProtocolError, .invalidSecurityTypes)
        }
        XCTAssertThrowsError(
            try RFBProtocol.parseSecurityTypes(Data([33]), expectedCount: 2)
        ) { error in
            XCTAssertEqual(error as? RFBProtocolError, .invalidSecurityTypes)
        }
    }

    func testPreservesMaximumSecurityTypeList() throws {
        let rawValues = Data((0...UInt8.max))

        let types = try RFBProtocol.parseSecurityTypes(
            rawValues,
            expectedCount: rawValues.count
        )

        XCTAssertEqual(types.map(\.rawValue), Array(0...UInt8.max))
    }
}
