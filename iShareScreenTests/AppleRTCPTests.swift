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

    func testBuildsNativeExtendedLegacyFullIntraRequest() {
        XCTAssertEqual(
            AppleRTCP.nativeLegacyFullIntraRequest(
                sender: 0x1122_3344,
                mediaSource: 0x5566_7788
            ).hex,
            "80c000021122334455667788"
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

    func testBuildsNativeCompatibleKeyFrameRequests() {
        let feedback = AppleRTCP.fullIntraRequest(
            sender: 0x1122_3344,
            mediaSource: 0x5566_7788,
            sequence: 7
        ) + AppleRTCP.pictureLossIndication(
            sender: 0x1122_3344,
            mediaSource: 0x5566_7788
        ) + AppleRTCP.legacyFullIntraRequest(mediaSource: 0x5566_7788)

        XCTAssertEqual(
            feedback.hex,
            "84ce00041122334400000000556677880700000081ce0002112233445566778880c0000155667788"
        )
    }

    func testBuildsAppleLongTermReferenceAcknowledgement() {
        XCTAssertEqual(
            AppleRTCP.longTermReferenceAcknowledgement(
                sender: 0x1122_3344,
                frameID: 0xabcd
            ).hex,
            "80cc000311223344000000050000abcd"
        )
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
