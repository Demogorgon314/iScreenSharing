import XCTest
@testable import iShareScreen

final class AppleHEVCDecodingOrderQueueTests: XCTestCase {
    func testBootstrapOrdersAccessUnitsAcrossSources() {
        var queue = AppleHEVCDecodingOrderQueue()

        let output = queue.enqueue([
            accessUnit(source: 200, decodingOrderNumber: 11),
            accessUnit(source: 100, decodingOrderNumber: 10),
        ])

        XCTAssertEqual(output.ready.map(\.decodingOrderNumber), [10, 11])
        XCTAssertFalse(output.requiresRefresh)
    }

    func testHoldsFutureAccessUnitAcrossBatchesUntilGapArrives() {
        var queue = AppleHEVCDecodingOrderQueue()
        _ = queue.enqueue([accessUnit(source: 100, decodingOrderNumber: 10)])

        XCTAssertTrue(queue.enqueue([
            accessUnit(source: 100, decodingOrderNumber: 12),
        ]).ready.isEmpty)
        XCTAssertEqual(
            queue.enqueue([accessUnit(source: 200, decodingOrderNumber: 11)]).ready.map(\.decodingOrderNumber),
            [11, 12]
        )
    }

    func testOrdersAcrossDecodingOrderWrap() {
        var queue = AppleHEVCDecodingOrderQueue()
        _ = queue.enqueue([accessUnit(source: 100, decodingOrderNumber: .max)])

        XCTAssertTrue(queue.enqueue([
            accessUnit(source: 200, decodingOrderNumber: 1),
        ]).ready.isEmpty)
        XCTAssertEqual(
            queue.enqueue([accessUnit(source: 100, decodingOrderNumber: 0)]).ready.map(\.decodingOrderNumber),
            [0, 1]
        )
    }

    func testRequestsRefreshInsteadOfGrowingPastReorderLimit() {
        var queue = AppleHEVCDecodingOrderQueue(maximumPendingCount: 2)
        _ = queue.enqueue([accessUnit(source: 100, decodingOrderNumber: 10)])

        XCTAssertFalse(queue.enqueue([
            accessUnit(source: 100, decodingOrderNumber: 12),
            accessUnit(source: 200, decodingOrderNumber: 13),
        ]).requiresRefresh)
        let output = queue.enqueue([accessUnit(source: 100, decodingOrderNumber: 14)])

        XCTAssertTrue(output.ready.isEmpty)
        XCTAssertTrue(output.requiresRefresh)
    }

    func testUnitsWithoutDecodingOrderRemainDecodable() {
        var queue = AppleHEVCDecodingOrderQueue()
        let unit = accessUnit(source: 100, decodingOrderNumber: nil)

        XCTAssertEqual(queue.enqueue([unit]).ready, [unit])
    }

    func testResetStartsAnewSequenceAndDiscardsPendingUnits() {
        var queue = AppleHEVCDecodingOrderQueue()
        _ = queue.enqueue([accessUnit(source: 100, decodingOrderNumber: 10)])
        _ = queue.enqueue([accessUnit(source: 100, decodingOrderNumber: 12)])

        queue.reset()
        let output = queue.enqueue([accessUnit(source: 200, decodingOrderNumber: 40)])

        XCTAssertEqual(output.ready.map(\.decodingOrderNumber), [40])
        XCTAssertFalse(output.requiresRefresh)
    }

    private func accessUnit(source: UInt32, decodingOrderNumber: UInt16?) -> AppleHEVCAccessUnit {
        AppleHEVCAccessUnit(
            synchronizationSource: source,
            timestamp: 0,
            decodingOrderNumber: decodingOrderNumber,
            nalUnits: [Data([0x02, 0x01, UInt8(truncatingIfNeeded: source)])]
        )
    }
}
