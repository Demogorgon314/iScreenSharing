import XCTest
@testable import iScreenSharing

final class MobileConnectionSectionsTests: XCTestCase {
    func testHistoryUsesLatestNameButKeepsSuccessfulConnectionOrder() throws {
        let first = try ConnectionEndpoint("first.local")
        let second = try ConnectionEndpoint("second.local")
        let history = [
            SavedConnection(endpoint: first, name: "Old name", lastConnectedAt: Date(timeIntervalSince1970: 10)),
            SavedConnection(endpoint: second, lastConnectedAt: Date(timeIntervalSince1970: 20)),
        ]
        let renamed = SavedConnection(endpoint: first, name: "Studio", lastConnectedAt: .now)
        let sections = MobileConnectionSections(saved: [renamed], recent: history, query: "")
        XCTAssertEqual(sections.recent.map(\.endpoint), [second, first])
        XCTAssertEqual(sections.recent.last?.name, "Studio")
        XCTAssertEqual(sections.recent.last?.lastConnectedAt, history.first?.lastConnectedAt)
        XCTAssertTrue(sections.saved.isEmpty)
    }

    func testSaveOnlyRemainsAccessibleWithoutInventingHistory() throws {
        let saved = SavedConnection(endpoint: try ConnectionEndpoint("studio.local"), name: "Studio")
        let sections = MobileConnectionSections(saved: [saved], recent: [], query: " STUDIO ")
        XCTAssertTrue(sections.recent.isEmpty)
        XCTAssertEqual(sections.saved, [saved])
        XCTAssertTrue(MobileConnectionSections(saved: [saved], recent: [], query: "missing").saved.isEmpty)
    }

    func testDuplicateHistoryAndSearchDoNotDuplicateRowsAcrossSections() throws {
        let entry = SavedConnection(endpoint: try ConnectionEndpoint("studio.local"))
        let sections = MobileConnectionSections(saved: [entry], recent: [entry, entry], query: "studio.local")
        XCTAssertEqual(sections.recent.count, 1)
        XCTAssertTrue(sections.saved.isEmpty)
    }
}
