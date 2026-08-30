import Foundation
import XCTest
import ScreenSharingProtocol

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

    func testClampsSignedCumulativeLossToRTCPFieldWidth() {
        let base = AppleRTPReceptionReport(
            source: 0,
            fractionLost: 0,
            cumulativePacketsLost: .max,
            extendedHighestSequence: 0,
            interarrivalJitter: 0,
            lastSenderReport: 0,
            delaySinceLastSenderReport: 0
        )
        let positive = AppleRTCP.receiverReport(sender: 0, report: base)
        XCTAssertEqual(positive[13..<16], Data([0x7f, 0xff, 0xff]))

        let negative = AppleRTPReceptionReport(
            source: 0,
            fractionLost: 0,
            cumulativePacketsLost: .min,
            extendedHighestSequence: 0,
            interarrivalJitter: 0,
            lastSenderReport: 0,
            delaySinceLastSenderReport: 0
        )
        XCTAssertEqual(
            AppleRTCP.receiverReport(sender: 0, report: negative)[13..<16],
            Data([0x80, 0x00, 0x00])
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
        XCTAssertEqual(nack.uint16BE(at: 12), 0)
        XCTAssertEqual(nack.uint16BE(at: 14), 1)
        XCTAssertEqual(nack.uint16BE(at: 16), UInt16.max)
    }

    func testEmptyNACKHasNoPacket() {
        XCTAssertTrue(
            AppleRTCP.genericNACK(sender: 1, mediaSource: 2, lostSequences: [UInt16]()).isEmpty
        )
    }

    func testBuildsNativeFeedbackPackets() {
        XCTAssertEqual(
            AppleRTCP.fullIntraRequest(
                sender: 0x1122_3344,
                mediaSource: 0x5566_7788,
                sequence: 7
            ).hex,
            "84ce000411223344000000005566778807000000"
        )
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
        XCTAssertEqual(
            AppleRTCP.longTermReferenceAcknowledgement(
                sender: 0x1122_3344,
                decodingOrderNumber: 0xabcd
            ).hex,
            "80cc000311223344000000050000abcd"
        )
    }

    func testBuildsRateControlPacketAndRejectsInvalidPayloadLength() {
        XCTAssertEqual(
            AppleRTCP.rateControl(sender: 0x1122_3344, mediaControlInfo: Data(0..<20)).hex,
            "80cc0007112233445243544c000102030405060708090a0b0c0d0e0f10111213"
        )
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

    func uint16BE(at offset: Int) -> UInt16? {
        guard offset >= 0, count >= offset + 2 else { return nil }
        return (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }
}
