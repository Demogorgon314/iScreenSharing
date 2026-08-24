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

    func testMeasuresEncodedBytesAndRecognizesRandomAccessPictures() {
        let accessUnit = AppleHEVCAccessUnit(
            synchronizationSource: 1,
            timestamp: 2,
            decodingOrderNumber: 3,
            nalUnits: [Data([0x26, 0x01, 0xaa]), Data([0x02, 0x01])]
        )

        XCTAssertEqual(accessUnit.encodedByteCount, 5)
        XCTAssertTrue(accessUnit.containsRandomAccessPicture)
    }

    func testRTPMediaControlBitsDoNotReplaceIRAPNALClassification() throws {
        let processor = try AppleHEVCStreamProcessor(keyBlob: Data(repeating: 0, count: 46))
        let ordinarySlice = Data([0x02, 0x01, 0, 1, 0xaa])
        let unit = try XCTUnwrap(processor.process(packet(
            sequence: 10,
            marker: true,
            payload: ordinarySlice,
            mediaControlBits: 0x02
        )))

        XCTAssertFalse(unit.containsRandomAccessPicture)
    }

    func testPropagatesLongTermReferenceMarkerToCompletedAccessUnit() throws {
        let processor = try AppleHEVCStreamProcessor(keyBlob: Data(repeating: 0, count: 46))
        let payload = Data([0x02, 0x01, 0, 1, 0xaa])

        XCTAssertNil(processor.process(packet(
            sequence: 10,
            marker: false,
            payload: payload,
            mediaControlBits: 0x01
        )))
        let unit = try XCTUnwrap(processor.process(packet(
            sequence: 11,
            marker: true,
            payload: payload
        )))

        XCTAssertTrue(unit.isLongTermReferenceFrame)
    }

    func testFirstPacketOwnsLongTermReferenceMarkerForAccessUnit() throws {
        let processor = try AppleHEVCStreamProcessor(keyBlob: Data(repeating: 0, count: 46))
        let payload = Data([0x02, 0x01, 0, 1, 0xaa])

        XCTAssertNil(processor.process(packet(
            sequence: 10,
            marker: false,
            payload: payload,
            mediaControlBits: 0
        )))
        let unit = try XCTUnwrap(processor.process(packet(
            sequence: 11,
            marker: true,
            payload: payload,
            mediaControlBits: 1
        )))

        XCTAssertFalse(unit.isLongTermReferenceFrame)
    }

    func testDeduplicatesRetransmittedSequenceNumbers() throws {
        let processor = try AppleHEVCStreamProcessor(keyBlob: Data(repeating: 0, count: 46))
        let payload = Data([0x42, 0x01, 0, 1, 0xaa])
        XCTAssertNil(processor.process(packet(sequence: 4, marker: false, payload: payload)))
        XCTAssertNil(processor.process(packet(sequence: 4, marker: false, payload: payload)))
        let unit = try XCTUnwrap(processor.process(packet(sequence: 5, marker: true, payload: payload)))
        XCTAssertEqual(unit.nalUnits.count, 2)
    }

    func testDropsIncompleteAccessUnitInsteadOfFeedingCorruptTile() throws {
        let processor = try AppleHEVCStreamProcessor(keyBlob: Data(repeating: 0, count: 46))
        let payload = Data([0x42, 0x01, 0, 1, 0xaa])

        XCTAssertNil(processor.process(packet(sequence: 10, marker: false, payload: payload)))
        XCTAssertNil(processor.process(packet(sequence: 12, marker: true, payload: payload)))
    }

    func testCompletesAccessUnitWhenMissingPacketArrivesAfterMarker() throws {
        let processor = try AppleHEVCStreamProcessor(keyBlob: Data(repeating: 0, count: 46))
        let payload = Data([0x42, 0x01, 0, 1, 0xaa])
        XCTAssertNil(processor.process(packet(sequence: 10, marker: false, payload: payload)))
        XCTAssertNil(processor.process(packet(sequence: 12, marker: true, payload: payload)))

        let unit = try XCTUnwrap(
            processor.process(packet(sequence: 11, marker: false, payload: payload))
        )

        XCTAssertEqual(unit.nalUnits.count, 3)
        XCTAssertEqual(unit.decodingOrderNumber, 1)
    }

    func testWaitsForFragmentStartThatArrivesAfterMarker() throws {
        let processor = try AppleHEVCStreamProcessor(keyBlob: Data(repeating: 0, count: 46))
        let start = Data([0x62, 0x01, 0x81, 0, 1, 0xaa])
        let continuation = Data([0x62, 0x01, 0x01, 0, 1, 0xbb])
        let end = Data([0x62, 0x01, 0x41, 0, 1, 0xcc])

        XCTAssertNil(processor.process(packet(
            sequence: 11,
            marker: false,
            payload: continuation
        )))
        XCTAssertNil(processor.process(packet(
            sequence: 12,
            marker: true,
            payload: end
        )))

        let unit = try XCTUnwrap(processor.process(packet(
            sequence: 10,
            marker: false,
            payload: start
        )))
        XCTAssertEqual(unit.nalUnits, [Data([0x02, 0x01, 0xaa, 0xbb, 0xcc])])
    }

    func testEvictsIncompleteAccessUnitBeyondNativePlayoutWindow() throws {
        let processor = try AppleHEVCStreamProcessor(keyBlob: Data(repeating: 0, count: 46))
        let oldPayload = Data([0x42, 0x01, 0, 1, 0xaa])
        let currentPayload = Data([0x42, 0x01, 0, 2, 0xbb])

        XCTAssertNil(processor.process(
            packet(sequence: 10, marker: false, payload: oldPayload, timestamp: 7)
        ))
        XCTAssertNil(processor.process(
            packet(sequence: 12, marker: true, payload: oldPayload, timestamp: 7)
        ))
        _ = processor.process(
            packet(sequence: 13, marker: true, payload: currentPayload, timestamp: 12_008)
        )

        XCTAssertNil(processor.process(
            packet(sequence: 11, marker: false, payload: oldPayload, timestamp: 7)
        ))
    }

    func testRetainsIncompleteAccessUnitAtNativePlayoutWindowBoundary() throws {
        let processor = try AppleHEVCStreamProcessor(keyBlob: Data(repeating: 0, count: 46))
        let oldPayload = Data([0x42, 0x01, 0, 1, 0xaa])
        let currentPayload = Data([0x42, 0x01, 0, 2, 0xbb])

        XCTAssertNil(processor.process(
            packet(sequence: 10, marker: false, payload: oldPayload, timestamp: 7)
        ))
        XCTAssertNil(processor.process(
            packet(sequence: 12, marker: true, payload: oldPayload, timestamp: 7)
        ))
        _ = processor.process(
            packet(sequence: 13, marker: true, payload: currentPayload, timestamp: 12_007)
        )

        XCTAssertNotNil(processor.process(
            packet(sequence: 11, marker: false, payload: oldPayload, timestamp: 7)
        ))
    }

    func testEvictsIncompleteAccessUnitAfterNativeHostTimeWindow() throws {
        let processor = try AppleHEVCStreamProcessor(keyBlob: Data(repeating: 0, count: 46))
        let payload = Data([0x42, 0x01, 0, 1, 0xaa])

        XCTAssertNil(processor.process(
            packet(sequence: 10, marker: false, payload: payload),
            arrivalTime: 1
        ))
        XCTAssertNil(processor.process(
            packet(sequence: 12, marker: true, payload: payload),
            arrivalTime: 1.01
        ))

        processor.expireIncompleteAccessUnits(at: 1.501)

        XCTAssertNil(processor.process(
            packet(sequence: 11, marker: false, payload: payload),
            arrivalTime: 1.502
        ))
    }

    func testRetainsIncompleteAccessUnitAtNativeHostTimeBoundary() throws {
        let processor = try AppleHEVCStreamProcessor(keyBlob: Data(repeating: 0, count: 46))
        let payload = Data([0x42, 0x01, 0, 1, 0xaa])

        XCTAssertNil(processor.process(
            packet(sequence: 10, marker: false, payload: payload),
            arrivalTime: 1
        ))
        XCTAssertNil(processor.process(
            packet(sequence: 12, marker: true, payload: payload),
            arrivalTime: 1.01
        ))

        processor.expireIncompleteAccessUnits(at: 1.5)

        XCTAssertNotNil(processor.process(
            packet(sequence: 11, marker: false, payload: payload),
            arrivalTime: 1.5
        ))
    }

    func testEvictsIncompleteAccessUnitAcrossRTPTimestampRollover() throws {
        let processor = try AppleHEVCStreamProcessor(keyBlob: Data(repeating: 0, count: 46))
        let oldTimestamp = UInt32.max - 10
        let currentTimestamp = oldTimestamp &+ 12_001
        let oldPayload = Data([0x42, 0x01, 0, 1, 0xaa])
        let currentPayload = Data([0x42, 0x01, 0, 2, 0xbb])

        XCTAssertNil(processor.process(
            packet(sequence: 10, marker: false, payload: oldPayload, timestamp: oldTimestamp)
        ))
        XCTAssertNil(processor.process(
            packet(sequence: 12, marker: true, payload: oldPayload, timestamp: oldTimestamp)
        ))
        _ = processor.process(
            packet(sequence: 13, marker: true, payload: currentPayload, timestamp: currentTimestamp)
        )

        XCTAssertNil(processor.process(
            packet(sequence: 11, marker: false, payload: oldPayload, timestamp: oldTimestamp)
        ))
    }

    func testRefreshDiscardClearsEveryIncompleteAccessUnit() throws {
        let processor = try AppleHEVCStreamProcessor(keyBlob: Data(repeating: 0, count: 46))
        let payload = Data([0x42, 0x01, 0, 1, 0xaa])

        XCTAssertNil(processor.process(
            packet(sequence: 10, marker: false, payload: payload, source: 100)
        ))
        XCTAssertNil(processor.process(
            packet(sequence: 12, marker: true, payload: payload, source: 100)
        ))
        XCTAssertNil(processor.process(
            packet(sequence: 20, marker: false, payload: payload, source: 200)
        ))

        processor.discardBufferedAccessUnits()

        XCTAssertNil(processor.process(
            packet(sequence: 11, marker: false, payload: payload, source: 100)
        ))
    }

    func testRejectsInconsistentDecodingOrderWithinOneSourceTimestamp() throws {
        let processor = try AppleHEVCStreamProcessor(keyBlob: Data(repeating: 0, count: 46))
        let firstPayload = Data([0x42, 0x01, 0, 1, 0xaa])
        let secondPayload = Data([0x42, 0x01, 0, 2, 0xbb])

        XCTAssertNil(processor.process(packet(sequence: 10, marker: false, payload: firstPayload)))
        XCTAssertNil(processor.process(packet(sequence: 11, marker: true, payload: secondPayload)))
        let unit = try XCTUnwrap(
            processor.process(packet(sequence: 11, marker: true, payload: firstPayload))
        )

        XCTAssertEqual(unit.decodingOrderNumber, 1)
        XCTAssertEqual(unit.nalUnits.count, 2)
    }

    func testEmitsNativeFrameLossFeedbackFromSenderDeclaredPacketCount() throws {
        let processor = try AppleHEVCStreamProcessor(keyBlob: Data(repeating: 0, count: 46))
        let payload = Data([0x42, 0x01, 0, 1, 0xaa])

        XCTAssertNil(processor.process(packet(
            sequence: 10,
            marker: false,
            payload: payload,
            totalPacketsPerFrame: 3,
            frameSequenceNumber: 9
        )))
        XCTAssertNotNil(processor.process(packet(
            sequence: 11,
            marker: true,
            payload: payload,
            totalPacketsPerFrame: 3,
            frameSequenceNumber: 9
        )))

        let first = processor.frameLossFeedbackDue(at: 1)
        XCTAssertEqual(first, [
            AppleVideoFrameLossFeedback(
                mediaSource: 0x1122_3344,
                rtpTimestamp: 7,
                expectedPacketCount: 3,
                lostPacketCount: 1
            ),
        ])
        processor.markFrameLossFeedbackSent(try XCTUnwrap(first.first), at: 1)
        XCTAssertTrue(processor.frameLossFeedbackDue(at: 1.099).isEmpty)
        XCTAssertEqual(processor.frameLossFeedbackDue(at: 1.101).count, 1)
    }

    func testLatePacketCorrectsCachedFrameLossFeedback() throws {
        let processor = try AppleHEVCStreamProcessor(keyBlob: Data(repeating: 0, count: 46))
        let payload = Data([0x42, 0x01, 0, 1, 0xaa])
        _ = processor.process(packet(
            sequence: 10,
            marker: false,
            payload: payload,
            totalPacketsPerFrame: 3,
            frameSequenceNumber: 9
        ))
        _ = processor.process(packet(
            sequence: 11,
            marker: true,
            payload: payload,
            totalPacketsPerFrame: 3,
            frameSequenceNumber: 9
        ))
        XCTAssertEqual(processor.frameLossFeedbackDue(at: 1).count, 1)

        _ = processor.process(packet(
            sequence: 9,
            marker: false,
            payload: payload,
            totalPacketsPerFrame: 3,
            frameSequenceNumber: 9
        ))

        XCTAssertTrue(processor.frameLossFeedbackDue(at: 1.2).isEmpty)
    }

    func testNewerFrameLossReplacesTheCachedRecordForOneSource() throws {
        let processor = try AppleHEVCStreamProcessor(keyBlob: Data(repeating: 0, count: 46))
        let firstPayload = Data([0x42, 0x01, 0, 1, 0xaa])
        let secondPayload = Data([0x42, 0x01, 0, 2, 0xbb])
        _ = processor.process(packet(
            sequence: 10,
            marker: true,
            payload: firstPayload,
            totalPacketsPerFrame: 2,
            frameSequenceNumber: 9
        ))
        _ = processor.process(packet(
            sequence: 11,
            marker: true,
            payload: secondPayload,
            timestamp: 8,
            totalPacketsPerFrame: 3,
            frameSequenceNumber: 10
        ))

        let feedback = processor.frameLossFeedbackDue(at: 1)
        XCTAssertEqual(feedback.count, 1)
        XCTAssertEqual(feedback.first?.rtpTimestamp, 8)
        XCTAssertEqual(feedback.first?.lostPacketCount, 2)
    }

    func testRetriesMissingPacketsUntilLatePacketArrives() throws {
        let processor = try AppleHEVCStreamProcessor(keyBlob: Data(repeating: 0, count: 46))
        XCTAssertNil(processor.process(
            packet(sequence: 10, marker: false, payload: Data([1])),
            arrivalTime: 1
        ))
        XCTAssertNil(processor.process(
            packet(sequence: 13, marker: false, payload: Data([1])),
            arrivalTime: 1.01
        ))

        let first = processor.missingSequencesDueForNACK(at: 1.01)
        XCTAssertEqual(first, [0x1122_3344: [11, 12]])
        processor.markNACKsSent(first, at: 1.01)
        XCTAssertTrue(processor.missingSequencesDueForNACK(at: 1.159).isEmpty)
        XCTAssertEqual(
            processor.missingSequencesDueForNACK(at: 1.161),
            [0x1122_3344: [11, 12]]
        )

        XCTAssertNil(processor.process(
            packet(sequence: 11, marker: false, payload: Data([1])),
            arrivalTime: 1.17
        ))
        XCTAssertEqual(
            processor.missingSequencesDueForNACK(at: 1.17),
            [0x1122_3344: [12]]
        )
    }

    func testExpiresMissingPacketsAfterNativeRetryLifetime() throws {
        let processor = try AppleHEVCStreamProcessor(keyBlob: Data(repeating: 0, count: 46))
        XCTAssertNil(processor.process(
            packet(sequence: 10, marker: false, payload: Data([1])),
            arrivalTime: 1
        ))
        XCTAssertNil(processor.process(
            packet(sequence: 12, marker: false, payload: Data([1])),
            arrivalTime: 1.01
        ))

        XCTAssertEqual(
            processor.missingSequencesDueForNACK(at: 1.01),
            [0x1122_3344: [11]]
        )
        XCTAssertTrue(processor.missingSequencesDueForNACK(at: 2.011).isEmpty)
    }

    func testLargeGapTracksOnlyNativeRecentSequenceWindow() {
        var tracker = AppleRTPSequenceTracker()
        tracker.observe(
            packet(sequence: 100, marker: false, payload: Data()),
            arrivalTime: 1
        )
        tracker.observe(
            packet(sequence: 200, marker: false, payload: Data()),
            arrivalTime: 1.01
        )

        XCTAssertEqual(
            tracker.missingSequencesDueForNACK(at: 1.01)[0x1122_3344],
            Array(UInt16(183)...UInt16(199))
        )
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
        XCTAssertEqual(processor.totalPacketCount, 0)
        XCTAssertTrue(processor.primarySources(tileCount: 1).isEmpty)
        XCTAssertTrue(processor.missingSequencesDueForNACK(at: 1).isEmpty)
    }

    func testSequenceTrackingHandlesRollover() {
        var tracker = AppleRTPSequenceTracker()
        tracker.observe(
            packet(sequence: UInt16.max, marker: false, payload: Data()),
            arrivalTime: 1
        )
        tracker.observe(
            packet(sequence: 1, marker: false, payload: Data()),
            arrivalTime: 1.01
        )
        XCTAssertEqual(
            tracker.missingSequencesDueForNACK(at: 1),
            [0x1122_3344: [0]]
        )
    }

    func testBuildsIntervalReceptionReportAcrossSequenceRollover() throws {
        var tracker = AppleRTPSequenceTracker()
        tracker.observe(
            packet(sequence: UInt16.max, marker: false, payload: Data(), timestamp: 24_000),
            arrivalTime: 1
        )
        tracker.observe(
            packet(sequence: 1, marker: false, payload: Data(), timestamp: 24_240),
            arrivalTime: 1.011
        )

        let first = try XCTUnwrap(tracker.receptionReport(for: 0x1122_3344))
        XCTAssertEqual(first.extendedHighestSequence, 0x0001_0001)
        XCTAssertEqual(first.cumulativePacketsLost, 1)
        XCTAssertEqual(first.fractionLost, 85)
        XCTAssertEqual(first.interarrivalJitter, 2)

        let second = try XCTUnwrap(tracker.receptionReport(for: 0x1122_3344))
        XCTAssertEqual(second.fractionLost, 0)
        XCTAssertEqual(second.cumulativePacketsLost, 1)
    }

    func testUsesDatagramArrivalTimeForReceptionStatistics() throws {
        let processor = try AppleHEVCStreamProcessor(keyBlob: Data(0..<46))
        let encrypted = Data([
            0x80, 0xe0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x11, 0x22, 0x33, 0x44, 0x8e, 0x12, 0xaf, 0xed,
            0x43, 0x36, 0xc6, 0x40, 0xf7, 0x96, 0x80, 0xaa,
            0xb7, 0x79, 0x04,
        ])

        _ = processor.process([
            AppleReceivedVideoDatagram(data: encrypted, arrivalTime: 1),
            AppleReceivedVideoDatagram(data: encrypted, arrivalTime: 1.01),
        ])

        let report = try XCTUnwrap(processor.receptionReport(for: 0x1122_3344))
        XCTAssertEqual(report.interarrivalJitter, 15)
    }

    func testRateControlUsesNativeSparseBandwidthProbeCadence() throws {
        let processor = try AppleHEVCStreamProcessor(keyBlob: Data(repeating: 0, count: 46))
        var sequence: UInt16 = 0

        func feedProbe(timestamp: UInt32, startTime: TimeInterval) {
            var start = Data([0x62, 0x01, 0x81, 0, 1])
            start.append(Data(repeating: 0xaa, count: 1_195))
            var end = Data([0x62, 0x01, 0x41, 0, 1])
            end.append(Data(repeating: 0xbb, count: 1_195))
            _ = processor.process(
                packet(sequence: sequence, marker: false, payload: start, timestamp: timestamp),
                arrivalTime: startTime
            )
            sequence &+= 1
            _ = processor.process(
                packet(sequence: sequence, marker: true, payload: end, timestamp: timestamp),
                arrivalTime: startTime + 0.005
            )
            sequence &+= 1
        }

        feedProbe(timestamp: 24_000, startTime: 10)
        for frame in 1..<120 {
            _ = processor.process(
                packet(
                    sequence: sequence,
                    marker: true,
                    payload: Data([0x02, 0x01, 0, 1, 0xaa]),
                    timestamp: 24_000 + UInt32(frame * 400)
                ),
                arrivalTime: 10.005 + Double(frame) / 60
            )
            sequence &+= 1
        }
        XCTAssertEqual(
            try XCTUnwrap(processor.rateControlFeedback(at: 12))
                .estimatedBandwidthKilobitsPerSecond,
            0
        )

        feedProbe(timestamp: 72_000, startTime: 12.01)
        feedProbe(timestamp: 120_000, startTime: 14.02)
        XCTAssertEqual(
            try XCTUnwrap(processor.rateControlFeedback(at: 14.03))
                .estimatedBandwidthKilobitsPerSecond,
            0
        )

        _ = processor.process(
            packet(
                sequence: sequence,
                marker: false,
                payload: Data([0x62, 0x01, 0x01, 0, 1, 0xcc]),
                timestamp: 168_000
            ),
            arrivalTime: 16.03
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(processor.rateControlFeedback(at: 16.03))
                .estimatedBandwidthKilobitsPerSecond,
            0
        )
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
        XCTAssertEqual(processor.totalPacketCount, 44)
        XCTAssertEqual(processor.packetCount(for: [100, 101, 102, 103]), 32)
        XCTAssertEqual(
            processor.primarySources(tileCount: 4, excluding: [100, 101, 102, 103]),
            [200, 201, 202, 203]
        )

        let baseline = processor.packetCounts
        for source in [UInt32(200), 201, 202, 203] {
            _ = processor.process(packet(sequence: 10, marker: true, payload: Data([0x42, 1, 0, 1, 1]), source: source))
        }
        XCTAssertEqual(
            processor.primarySources(tileCount: 4, packetCountBaseline: baseline),
            [200, 201, 202, 203]
        )
    }

    private func packet(
        sequence: UInt16,
        marker: Bool,
        payload: Data,
        source: UInt32 = 0x1122_3344,
        timestamp: UInt32 = 7,
        mediaControlBits: UInt8? = nil,
        totalPacketsPerFrame: UInt16? = nil,
        frameSequenceNumber: UInt16 = 0
    ) -> AppleRTPPacket {
        var header = Data()
        if let totalPacketsPerFrame {
            header = Data([
                0x90, 0x60, 0, 0, 0, 0, 0, 0, 0x11, 0x22, 0x33, 0x44,
                0x93, ((mediaControlBits ?? 0) << 4) | 0x01, 0, 1,
            ])
            header.append(contentsOf: [
                UInt8(truncatingIfNeeded: totalPacketsPerFrame >> 8),
                UInt8(truncatingIfNeeded: totalPacketsPerFrame),
                UInt8(truncatingIfNeeded: frameSequenceNumber >> 8),
                UInt8(truncatingIfNeeded: frameSequenceNumber),
            ])
        } else if let mediaControlBits {
            header = Data([
                0x90, 0x60, 0, 0, 0, 0, 0, 0, 0x11, 0x22, 0x33, 0x44,
                0x93, mediaControlBits << 4, 0, 0,
            ])
        }
        return AppleRTPPacket(
            header: header,
            payload: payload,
            sequenceNumber: sequence,
            timestamp: timestamp,
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
