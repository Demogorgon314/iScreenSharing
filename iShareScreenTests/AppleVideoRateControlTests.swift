import XCTest
@testable import iShareScreen

final class AppleVideoRateControlTests: XCTestCase {
    func testSerializesNativeGoldenVector() {
        let feedback = AppleVideoRateControlInfo(
            rtpTimestamp: 106_500,
            estimatedBandwidthKilobitsPerSecond: 32_001,
            burstyLoss: 0,
            receivedPacketCount: 67,
            feedbackDelayMilliseconds: 66,
            echoTimestamp: AppleVideoRateControlInfo.echoTimestamp(at: 1_000.25),
            oneWayReceiveDelay: 0
        )

        XCTAssertEqual(
            feedback.serialized().hex,
            "85000004a004000000000042a100000000437d01"
        )
    }

    func testClampsBoundedFieldsAndPacksDelay() throws {
        let payload = AppleVideoRateControlInfo(
            rtpTimestamp: 1,
            estimatedBandwidthKilobitsPerSecond: 2,
            burstyLoss: 20,
            receivedPacketCount: 0x1abc,
            feedbackDelayMilliseconds: UInt32.max,
            echoTimestamp: 3,
            oneWayReceiveDelay: 0.5
        ).serialized()

        XCTAssertEqual(try payload.uint16BE(at: 10), UInt16.max)
        XCTAssertEqual(try payload.uint16BE(at: 14), 4_096)
        XCTAssertEqual(try payload.uint16BE(at: 16), 0xfabc)
    }

    func testInvalidTimesDegradeToZero() throws {
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
        XCTAssertEqual(try payload.uint16BE(at: 14), 0)
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
