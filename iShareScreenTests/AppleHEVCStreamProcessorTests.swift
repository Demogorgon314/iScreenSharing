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
        XCTAssertEqual(unit.decodingOrderNumber, 1)
        XCTAssertEqual(
            processor.currentParameterSets(),
            AppleHEVCParameterSets(video: vps, sequence: sps, pictures: [pps])
        )
    }

    func testExtractsDecodingOrderNumberFromFragmentedUnit() {
        XCTAssertEqual(
            AppleHEVCNALUnit.firstDecodingOrderNumber(
                in: [Data([0x62, 0x01, 0x81, 0xab, 0xcd, 0xff])]
            ),
            0xabcd
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

    func testTracksSequenceGapsAndCancelsNACKForLatePacket() throws {
        let processor = try AppleHEVCStreamProcessor(keyBlob: Data(repeating: 0, count: 46))
        XCTAssertNil(processor.process(packet(sequence: 10, marker: false, payload: Data([1]))))
        XCTAssertNil(processor.process(packet(sequence: 13, marker: false, payload: Data([1]))))
        XCTAssertNil(processor.process(packet(sequence: 11, marker: false, payload: Data([1]))))

        XCTAssertEqual(processor.drainMissingSequences(), [0x1122_3344: [12]])
        XCTAssertTrue(processor.drainMissingSequences().isEmpty)
    }

    func testResetDiscardsSourcesParametersAndMissingSequences() throws {
        let processor = try AppleHEVCStreamProcessor(keyBlob: Data(repeating: 0, count: 46))
        let parameterPayload = aggregationPayload([
            Data([0x40, 0x01, 1]), Data([0x42, 0x01, 2]), Data([0x44, 0x01, 3]),
        ])
        _ = processor.process(packet(sequence: 10, marker: true, payload: parameterPayload))
        _ = processor.process(packet(sequence: 13, marker: false, payload: Data([1])))

        processor.reset()

        XCTAssertEqual(processor.currentParameterSets(), AppleHEVCParameterSets())
        XCTAssertTrue(processor.primarySources(tileCount: 1).isEmpty)
        XCTAssertTrue(processor.drainMissingSequences().isEmpty)
    }

    func testSequenceTrackingHandlesRollover() {
        var tracker = AppleRTPSequenceTracker()
        tracker.observe(packet(sequence: UInt16.max, marker: false, payload: Data()))
        tracker.observe(packet(sequence: 1, marker: false, payload: Data()))
        XCTAssertEqual(tracker.drainMissingSequences(), [0x1122_3344: [0]])
    }

    func testPrimarySourcesSelectsBusiestCompleteGroupAndCanExcludeIt() throws {
        let processor = try AppleHEVCStreamProcessor(keyBlob: Data(repeating: 0, count: 46))
        for sequence in 0..<8 {
            for source in [UInt32(100), 101, 102, 103] {
                _ = processor.process(packet(sequence: UInt16(sequence), marker: true, payload: Data([0x42, 1, 0, 1, 1]), source: source))
            }
        }
        for sequence in 0..<3 {
            for source in [UInt32(200), 201, 202, 203] {
                _ = processor.process(packet(sequence: UInt16(sequence), marker: true, payload: Data([0x42, 1, 0, 1, 1]), source: source))
            }
        }

        XCTAssertEqual(processor.primarySources(tileCount: 4), [100, 101, 102, 103])
        XCTAssertEqual(
            processor.primarySources(tileCount: 4, excluding: [100, 101, 102, 103]),
            [200, 201, 202, 203]
        )
    }

    private func packet(
        sequence: UInt16,
        marker: Bool,
        payload: Data,
        source: UInt32 = 0x1122_3344
    ) -> AppleRTPPacket {
        AppleRTPPacket(
            header: Data(),
            payload: payload,
            sequenceNumber: sequence,
            timestamp: 7,
            synchronizationSource: source,
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
