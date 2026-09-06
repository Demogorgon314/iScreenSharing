import XCTest
@testable import iScreenSharingMobile

final class MobileConnectionDraftTests: XCTestCase {
    func testBuildsDefaultPortEndpoint() throws {
        let draft = MobileConnectionDraft(address: "studio-mac.local")

        let endpoint = try draft.endpoint()

        XCTAssertEqual(endpoint.host, "studio-mac.local")
        XCTAssertEqual(endpoint.port, 5_900)
    }

    func testBuildsExplicitPortEndpoint() throws {
        let draft = MobileConnectionDraft(address: "vnc://192.0.2.10:5901")

        let endpoint = try draft.endpoint()

        XCTAssertEqual(endpoint.host, "192.0.2.10")
        XCTAssertEqual(endpoint.port, 5_901)
    }

    func testRejectsEmptyAddress() {
        let draft = MobileConnectionDraft(address: "  ")

        XCTAssertThrowsError(try draft.endpoint()) { error in
            XCTAssertEqual(error as? ConnectionEndpointError, .empty)
        }
    }
}
