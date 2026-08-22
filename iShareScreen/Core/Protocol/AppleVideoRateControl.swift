import Foundation

struct AppleVideoRateControlInfo: Equatable, Sendable {
    let rtpTimestamp: UInt32
    let estimatedBandwidthKilobitsPerSecond: UInt32
    let burstyLoss: UInt16
    let receivedPacketCount: UInt32
    let feedbackDelayMilliseconds: UInt32
    let echoTimestamp: UInt16
    let oneWayReceiveDelay: TimeInterval

    func serialized() -> Data {
        var payload = Data([0x85, 0, 0, 4])
        payload.appendUInt16BE(UInt16(truncatingIfNeeded: rtpTimestamp))
        payload.appendUInt16BE(0)
        payload.appendUInt16BE(0)
        payload.appendUInt16BE(UInt16(clamping: feedbackDelayMilliseconds))
        payload.appendUInt16BE(echoTimestamp)
        payload.appendUInt16BE(UInt16(clamping: Self.packedRTPTime(oneWayReceiveDelay)))
        payload.appendUInt16BE(
            min(burstyLoss, 15) << 12
                | UInt16(truncatingIfNeeded: receivedPacketCount) & 0x0fff
        )
        payload.appendUInt16BE(UInt16(truncatingIfNeeded: estimatedBandwidthKilobitsPerSecond))
        return payload
    }

    static func echoTimestamp(at time: TimeInterval) -> UInt16 {
        guard time.isFinite, time > 0 else { return 0 }
        let scaled = time * 1_024
        guard scaled < Double(UInt64.max) else { return UInt16.max }
        return UInt16(truncatingIfNeeded: UInt64(scaled.rounded(.towardZero)))
    }

    private static func packedRTPTime(_ seconds: TimeInterval) -> UInt32 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let scaled = seconds * 8_192
        guard scaled < Double(UInt32.max) else { return UInt32.max }
        return UInt32(scaled.rounded(.down))
    }
}
