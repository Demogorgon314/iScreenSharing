import XCTest
@testable import iShareScreen

final class AppleHEVCDecodingOrderQueueTests: XCTestCase {
    func testBootstrapOrdersAccessUnitsAcrossSources() {
        var queue = AppleHEVCDecodingOrderQueue()

        let output = queue.enqueue([
            accessUnit(source: 200, decodingOrderNumber: 11),
            accessUnit(source: 100, decodingOrderNumber: 10),
        ])

        XCTAssertEqual(output.accessUnits.map(\.decodingOrderNumber), [10, 11])
    }

    func testForwardAccessUnitAdvancesImmediatelyAndLateGapIsDropped() {
        var queue = AppleHEVCDecodingOrderQueue()
        _ = queue.enqueue([accessUnit(source: 100, decodingOrderNumber: 10)])

        XCTAssertEqual(
            queue.enqueue([accessUnit(source: 100, decodingOrderNumber: 12)])
                .accessUnits.map(\.decodingOrderNumber),
            [12]
        )
        XCTAssertTrue(
            queue.enqueue([accessUnit(source: 200, decodingOrderNumber: 11)])
                .accessUnits.isEmpty
        )
    }

    func testOrdersAcrossDecodingOrderWrap() {
        var queue = AppleHEVCDecodingOrderQueue()
        _ = queue.enqueue([accessUnit(source: 100, decodingOrderNumber: .max)])

        XCTAssertEqual(
            queue.enqueue([accessUnit(source: 200, decodingOrderNumber: 1)])
                .accessUnits.map(\.decodingOrderNumber),
            [1]
        )
        XCTAssertTrue(
            queue.enqueue([accessUnit(source: 100, decodingOrderNumber: 0)])
                .accessUnits.isEmpty
        )
    }

    func testForwardGapDoesNotWaitForAnArbitraryPendingLimit() {
        var queue = AppleHEVCDecodingOrderQueue()
        _ = queue.enqueue([accessUnit(source: 100, decodingOrderNumber: 10)])

        let output = queue.enqueue([
            accessUnit(source: 100, decodingOrderNumber: 12),
            accessUnit(source: 200, decodingOrderNumber: 13),
        ])

        XCTAssertEqual(output.accessUnits.map(\.decodingOrderNumber), [12, 13])
        XCTAssertTrue(
            queue.enqueue([accessUnit(source: 200, decodingOrderNumber: 11)])
                .accessUnits.isEmpty
        )
    }

    func testRandomAccessPicturesUseTheSameForwardAdmissionRules() {
        var queue = AppleHEVCDecodingOrderQueue()
        _ = queue.enqueue([accessUnit(source: 100, decodingOrderNumber: 10)])

        let output = queue.enqueue([
            accessUnit(
                source: 200,
                decodingOrderNumber: 12,
                isRandomAccessPicture: true
            ),
            accessUnit(
                source: 100,
                decodingOrderNumber: 11,
                isRandomAccessPicture: true
            ),
        ])

        XCTAssertEqual(
            output.accessUnits.map(\.decodingOrderNumber),
            [12]
        )
        XCTAssertTrue(
            queue.enqueue([
                accessUnit(
                    source: 100,
                    decodingOrderNumber: 11,
                    isRandomAccessPicture: true
                )
            ])
                .accessUnits.isEmpty
        )
    }

    func testUnitsWithoutDecodingOrderRemainDecodable() {
        var queue = AppleHEVCDecodingOrderQueue()
        let unit = accessUnit(source: 100, decodingOrderNumber: nil)

        XCTAssertEqual(queue.enqueue([unit]).accessUnits, [unit])
    }

    private func accessUnit(
        source: UInt32,
        decodingOrderNumber: UInt16?,
        isRefresh: Bool = false,
        isRandomAccessPicture: Bool? = nil
    ) -> AppleHEVCAccessUnit {
        AppleHEVCAccessUnit(
            synchronizationSource: source,
            timestamp: 0,
            decodingOrderNumber: decodingOrderNumber,
            nalUnits: [Data([
                (isRandomAccessPicture ?? isRefresh) ? 0x26 : 0x02,
                0x01,
                UInt8(truncatingIfNeeded: source),
            ])]
        )
    }
}
