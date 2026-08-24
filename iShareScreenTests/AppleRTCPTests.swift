import XCTest
@testable import iShareScreen

final class AppleRTCPTests: XCTestCase {
    func testBuildsReceiverReportWithNativeSourceStatistics() {
        let report = AppleRTPReceptionReport(
            source: 0x5566_7788,
            fractionLost: 0x40,
            cumulativePacketsLost: 2,
            extendedHighestSequence: 0x1234_5678,
            interarrivalJitter: 90,
            lastSenderReport: 0x0102_0304,
            delaySinceLastSenderReport: 0x0506_0708
        )

        XCTAssertEqual(
            AppleRTCP.receiverReport(sender: 0x1122_3344, report: report).hex,
            "81c90007112233445566778840000002123456780000005a0102030405060708"
        )
    }

    func testBuildsCompoundGenericNACKMatchingReference() {
        let nack = AppleRTCP.genericNACK(
            sender: 0x1122_3344,
            mediaSource: 0x5566_7788,
            lostSequences: [10, 11, 13, 30]
        )

        XCTAssertEqual(
            AppleRTCP.compound(sender: 0x1122_3344, feedback: nack).hex,
            "80c900011122334481cd00041122334455667788000a0005001e0000"
        )
    }

    func testCoalescesDuplicateAndWrappedNACKSequences() {
        let nack = AppleRTCP.genericNACK(
            sender: 1,
            mediaSource: 2,
            lostSequences: [UInt16.max, 0, 0, 1]
        )

        XCTAssertEqual(nack.count, 20)
        XCTAssertEqual(try nack.uint16BE(at: 12), 0)
        XCTAssertEqual(try nack.uint16BE(at: 14), 1)
        XCTAssertEqual(try nack.uint16BE(at: 16), UInt16.max)
    }

    func testEmptyNACKHasNoPacket() {
        XCTAssertTrue(
            AppleRTCP.genericNACK(sender: 1, mediaSource: 2, lostSequences: [UInt16]()).isEmpty
        )
    }

    func testBuildsNativeHighPerformanceKeyFrameRequest() {
        let feedback = AppleRTCP.fullIntraRequest(
            sender: 0x1122_3344,
            mediaSource: 0x5566_7788,
            sequence: 7
        )

        XCTAssertEqual(
            feedback.hex,
            "84ce000411223344000000005566778807000000"
        )
    }

    func testBuildsNativeFrameLossFeedback() {
        XCTAssertEqual(
            AppleRTCP.frameLossFeedback(
                sender: 0x1122_3344,
                mediaSource: 0x5566_7788,
                rtpTimestamp: 0x99aa_bbcc,
                packedLoss: 0x1234,
                framePacketCount: 0x56,
                frameLostPacketCount: 0x78
            ).hex,
            "8fce000511223344556677880000000699aabbcc12345678"
        )
    }

    func testBuildsAppleLongTermReferenceAcknowledgement() {
        XCTAssertEqual(
            AppleRTCP.longTermReferenceAcknowledgement(
                sender: 0x1122_3344,
                decodingOrderNumber: 0xabcd
            ).hex,
            "80cc000311223344000000050000abcd"
        )
    }

    func testBuildsStandaloneRateControlPacket() {
        XCTAssertEqual(
            AppleRTCP.rateControl(sender: 0x1122_3344, mediaControlInfo: Data(0..<20)).hex,
            "80cc0007112233445243544c000102030405060708090a0b0c0d0e0f10111213"
        )
    }

    func testRejectsInvalidRateControlPayloadLength() {
        XCTAssertTrue(
            AppleRTCP.rateControl(
                sender: 1,
                mediaControlInfo: Data(repeating: 0, count: 19)
            ).isEmpty
        )
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
