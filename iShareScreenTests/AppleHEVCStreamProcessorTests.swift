import XCTest
@testable import iShareScreen

final class AppleHEVCStreamProcessorTests: XCTestCase {
    func testGroupsPacketsSortsAcrossSequenceWrapAndHarvestsParameters() throws {
        let processor = try AppleHEVCStreamProcessor(keyBlob: Data(repeating: 0, count: 46))
        let vps = Data([0x40, 0x01, 0xaa])
        let sps = Data([0x42, 0x01, 0xbb])
        let pps = Data([0x44, 0x01, 0xcc])
        let firstPayload = aggregationPayload([vps, sps])
        let secondPayload = aggregationPayload([pps])

        XCTAssertNil(processor.process(packet(sequence: .max, marker: false, payload: firstPayload)))
        let unit = try XCTUnwrap(
            processor.process(packet(sequence: 0, marker: true, payload: secondPayload))
        )

        XCTAssertEqual(unit.nalUnits, [vps, sps, pps])
        XCTAssertEqual(
            processor.currentParameterSets(),
            AppleHEVCParameterSets(video: vps, sequence: sps, pictures: [pps])
        )
    }

    func testDeduplicatesRetransmittedSequenceNumbers() throws {
        let processor = try AppleHEVCStreamProcessor(keyBlob: Data(repeating: 0, count: 46))
        let payload = Data([0x42, 0x01, 0, 1, 0xaa])
        XCTAssertNil(processor.process(packet(sequence: 4, marker: false, payload: payload)))
        XCTAssertNil(processor.process(packet(sequence: 4, marker: false, payload: payload)))
        let unit = try XCTUnwrap(processor.process(packet(sequence: 5, marker: true, payload: payload)))
        XCTAssertEqual(unit.nalUnits.count, 2)
    }

    private func packet(sequence: UInt16, marker: Bool, payload: Data) -> AppleRTPPacket {
        AppleRTPPacket(
            header: Data(),
            payload: payload,
            sequenceNumber: sequence,
            timestamp: 7,
            synchronizationSource: 0x1122_3344,
            payloadType: 96,
            marker: marker
        )
    }

    private func aggregationPayload(_ units: [Data]) -> Data {
        var payload = Data([0x60, 0x01, 0, 1])
        for unit in units {
            payload.appendUInt16BE(UInt16(unit.count))
            payload.append(unit)
        }
        return payload
    }
}
