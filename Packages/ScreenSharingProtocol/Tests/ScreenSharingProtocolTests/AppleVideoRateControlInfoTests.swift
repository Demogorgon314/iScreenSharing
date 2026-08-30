import Foundation
import XCTest
import ScreenSharingProtocol

final class AppleVideoRateControlInfoTests: XCTestCase {
    func testSerializesNativeGoldenVector() {
        let feedback = AppleVideoRateControlInfo(
            rtpTimestamp: 106_500,
            estimatedBandwidthKilobitsPerSecond: 32_001,
            burstyLoss: 0,
            receivedPacketCount: 67,
            feedbackDelayMilliseconds: 66,
            echoTimestamp: AppleVideoRateControlInfo.echoTimestamp(at: 1_000.25),
            oneWayReceiveDelay: 0.0136
        )

        XCTAssertEqual(
            feedback.serialized(),
            Data([
                0x85, 0x00, 0x00, 0x04, 0x01, 0xa0, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x42, 0xa1, 0x00, 0x00, 0x6f,
                0x00, 0x43, 0x7d, 0x01,
            ])
        )
    }

    func testClampsBoundedFieldsAndPacksOneWayReceiveDelay() {
        let payload = AppleVideoRateControlInfo(
            rtpTimestamp: 1,
            estimatedBandwidthKilobitsPerSecond: 2,
            burstyLoss: 20,
            receivedPacketCount: 0x1abc,
            feedbackDelayMilliseconds: UInt32.max,
            echoTimestamp: 3,
            oneWayReceiveDelay: 0.5
        ).serialized()

        XCTAssertEqual(payload.uint16BE(at: 10), UInt16.max)
        XCTAssertEqual(payload.uint16BE(at: 14), 4_096)
        XCTAssertEqual(payload.uint16BE(at: 16), 0xfabc)
    }

    func testPacksNativeRuntimeOneWayReceiveDelayAndClampsLargeValues() {
        let runtimeValue = AppleVideoRateControlInfo(
            rtpTimestamp: 0,
            estimatedBandwidthKilobitsPerSecond: 0,
            burstyLoss: 0,
            receivedPacketCount: 0,
            feedbackDelayMilliseconds: 0,
            echoTimestamp: 0,
            oneWayReceiveDelay: 0.0136
        ).serialized()
        let largeValue = AppleVideoRateControlInfo(
            rtpTimestamp: 0,
            estimatedBandwidthKilobitsPerSecond: 0,
            burstyLoss: 0,
            receivedPacketCount: 0,
            feedbackDelayMilliseconds: 0,
            echoTimestamp: 0,
            oneWayReceiveDelay: 8
        ).serialized()

        XCTAssertEqual(runtimeValue.uint16BE(at: 14), 111)
        XCTAssertEqual(largeValue.uint16BE(at: 14), UInt16.max)
    }

    func testSerializesNativeLowPrecisionTimestampAcrossLowWordBoundary() {
        let payload = AppleVideoRateControlInfo(
            rtpTimestamp: 0x1234_abcd,
            estimatedBandwidthKilobitsPerSecond: 0,
            burstyLoss: 0,
            receivedPacketCount: 0,
            feedbackDelayMilliseconds: 0,
            echoTimestamp: 0,
            oneWayReceiveDelay: 0
        ).serialized()

        XCTAssertEqual(payload.uint16BE(at: 4), 0x34ab)
    }

    func testInvalidTimesDegradeToZero() {
        XCTAssertEqual(AppleVideoRateControlInfo.echoTimestamp(at: -.infinity), 0)
        let payload = AppleVideoRateControlInfo(
            rtpTimestamp: 0,
            estimatedBandwidthKilobitsPerSecond: 0,
            burstyLoss: 0,
            receivedPacketCount: 0,
            feedbackDelayMilliseconds: 0,
            echoTimestamp: 0,
            oneWayReceiveDelay: .nan
        ).serialized()
        XCTAssertEqual(payload.uint16BE(at: 14), 0)
    }
}

private extension Data {
    func uint16BE(at offset: Int) -> UInt16? {
        guard offset >= 0, count >= offset + 2 else { return nil }
        return UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }
}
