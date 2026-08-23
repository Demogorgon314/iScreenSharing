import XCTest
@testable import iShareScreen

final class AppleHEVCNALUnitTests: XCTestCase {
    func testClassifiesNativeAccessUnitStartPackets() {
        XCTAssertTrue(AppleHEVCNALUnit.startsAccessUnit(
            Data([0x42, 0x01, 0, 1])
        ))
        XCTAssertTrue(AppleHEVCNALUnit.startsAccessUnit(
            Data([0x60, 0x01, 0, 1])
        ))
        XCTAssertTrue(AppleHEVCNALUnit.startsAccessUnit(
            Data([0x62, 0x01, 0x81, 0, 1])
        ))
        XCTAssertFalse(AppleHEVCNALUnit.startsAccessUnit(
            Data([0x62, 0x01, 0x01, 0, 1])
        ))
        XCTAssertFalse(AppleHEVCNALUnit.startsAccessUnit(
            Data([0x62, 0x01, 0x81, 0])
        ))
    }

    func testExtractsAggregationPacketUnits() {
        let first = Data([0x40, 0x01, 0xaa])
        let second = Data([0x42, 0x01, 0xbb, 0xcc])
        var payload = Data([0x60, 0x01, 0x00, 0x07])
        payload.appendUInt16BE(UInt16(first.count))
        payload.append(first)
        payload.appendUInt16BE(UInt16(second.count))
        payload.append(second)

        XCTAssertEqual(AppleHEVCNALUnit.reassemble([payload]), [first, second])
    }

    func testReassemblesFragmentationUnitsAndRemovesEveryDONL() {
        let start = Data([0x62, 0x01, 0x93, 0x12, 0x34, 0xaa, 0xbb])
        let middle = Data([0x62, 0x01, 0x13, 0x12, 0x34, 0xcc])
        let end = Data([0x62, 0x01, 0x53, 0x12, 0x34, 0xdd])

        XCTAssertEqual(
            AppleHEVCNALUnit.reassemble([start, middle, end]),
            [Data([0x26, 0x01, 0xaa, 0xbb, 0xcc, 0xdd])]
        )
    }

    func testRemovesDONLFromSingleNALUnit() {
        let payload = Data([0x42, 0x01, 0xde, 0xad, 0xaa, 0xbb])
        XCTAssertEqual(
            AppleHEVCNALUnit.reassemble([payload]),
            [Data([0x42, 0x01, 0xaa, 0xbb])]
        )
    }

    func testDropsMalformedAndOrphanFragments() {
        XCTAssertTrue(AppleHEVCNALUnit.reassemble([
            Data([0x62, 0x01, 0x53, 0, 1, 0xaa]),
            Data([0x60, 0x01, 0, 0, 0, 8, 0xaa]),
        ]).isEmpty)
    }

    func testDropsEntireMalformedAggregationPacket() {
        let validUnit = Data([0x40, 0x01, 0xaa])
        var truncatedUnit = Data([0x60, 0x01, 0, 0])
        truncatedUnit.appendUInt16BE(UInt16(validUnit.count))
        truncatedUnit.append(validUnit)
        truncatedUnit.append(0xff)

        var overrunUnit = Data([0x60, 0x01, 0, 0])
        overrunUnit.appendUInt16BE(UInt16(validUnit.count))
        overrunUnit.append(validUnit)
        overrunUnit.appendUInt16BE(8)
        overrunUnit.append(0xaa)

        XCTAssertTrue(AppleHEVCNALUnit.reassemble([truncatedUnit]).isEmpty)
        XCTAssertTrue(AppleHEVCNALUnit.reassemble([overrunUnit]).isEmpty)
    }
}
