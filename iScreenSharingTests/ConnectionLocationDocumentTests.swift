import XCTest
@testable import iScreenSharing

final class ConnectionLocationDocumentTests: XCTestCase {
    func testRoundTripsSystemCompatibleVNCInternetLocation() throws {
        let endpoint = try ConnectionEndpoint("vnc://192.168.50.239:5901")

        let data = try ConnectionLocationDocument.data(for: endpoint)
        let propertyList = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        )

        XCTAssertEqual(propertyList, ["URL": "vnc://192.168.50.239:5901"])
        XCTAssertEqual(try ConnectionLocationDocument.endpoint(from: data), endpoint)
    }

    func testReadsBinaryInternetLocationPropertyList() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["URL": "vnc://deepdream.local"],
            format: .binary,
            options: 0
        )

        XCTAssertEqual(
            try ConnectionLocationDocument.endpoint(from: data),
            try ConnectionEndpoint("deepdream.local")
        )
    }

    func testRejectsMalformedDocumentsAndAddresses() throws {
        XCTAssertThrowsError(try ConnectionLocationDocument.endpoint(from: Data("not a plist".utf8))) {
            XCTAssertEqual($0 as? ConnectionLocationDocumentError, .invalidDocument)
        }
        let invalidAddress = try PropertyListSerialization.data(
            fromPropertyList: ["URL": "https://example.com"],
            format: .xml,
            options: 0
        )
        XCTAssertThrowsError(try ConnectionLocationDocument.endpoint(from: invalidAddress)) {
            XCTAssertEqual($0 as? ConnectionLocationDocumentError, .invalidAddress)
        }
    }
}
