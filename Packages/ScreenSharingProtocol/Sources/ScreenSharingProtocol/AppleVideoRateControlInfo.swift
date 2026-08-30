import Foundation

/// The 20-byte media-control value carried by Apple's RCTL RTCP APP packet.
public struct AppleVideoRateControlInfo: Equatable, Sendable {
    public let rtpTimestamp: UInt32
    public let estimatedBandwidthKilobitsPerSecond: UInt32
    public let burstyLoss: UInt16
    public let receivedPacketCount: UInt32
    public let feedbackDelayMilliseconds: UInt32
    public let echoTimestamp: UInt16
    public let oneWayReceiveDelay: TimeInterval

    public init(
        rtpTimestamp: UInt32,
        estimatedBandwidthKilobitsPerSecond: UInt32,
        burstyLoss: UInt16,
        receivedPacketCount: UInt32,
        feedbackDelayMilliseconds: UInt32,
        echoTimestamp: UInt16,
        oneWayReceiveDelay: TimeInterval
    ) {
        self.rtpTimestamp = rtpTimestamp
        self.estimatedBandwidthKilobitsPerSecond = estimatedBandwidthKilobitsPerSecond
        self.burstyLoss = burstyLoss
        self.receivedPacketCount = receivedPacketCount
        self.feedbackDelayMilliseconds = feedbackDelayMilliseconds
        self.echoTimestamp = echoTimestamp
        self.oneWayReceiveDelay = oneWayReceiveDelay
    }

    public func serialized() -> Data {
        var payload = Data([0x85, 0, 0, 4])
        // Native HP streams enable the low-precision timestamp form before
        // serializing RCTL feedback, so the wire field carries bits 8...23.
        BigEndianWire.append(UInt16(truncatingIfNeeded: rtpTimestamp >> 8), to: &payload)
        BigEndianWire.append(UInt16(0), to: &payload)
        BigEndianWire.append(UInt16(0), to: &payload)
        BigEndianWire.append(UInt16(clamping: feedbackDelayMilliseconds), to: &payload)
        BigEndianWire.append(echoTimestamp, to: &payload)
        BigEndianWire.append(Self.packedOneWayReceiveDelay(oneWayReceiveDelay), to: &payload)
        BigEndianWire.append(
            min(burstyLoss, 15) << 12
                | UInt16(truncatingIfNeeded: receivedPacketCount) & 0x0fff,
            to: &payload
        )
        BigEndianWire.append(
            UInt16(truncatingIfNeeded: estimatedBandwidthKilobitsPerSecond),
            to: &payload
        )
        return payload
    }

    public static func echoTimestamp(at time: TimeInterval) -> UInt16 {
        guard time.isFinite, time > 0 else { return 0 }
        let scaled = time * 1_024
        guard scaled < Double(UInt64.max) else { return UInt16.max }
        return UInt16(truncatingIfNeeded: UInt64(scaled.rounded(.towardZero)))
    }

    private static func packedOneWayReceiveDelay(_ seconds: TimeInterval) -> UInt16 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let scaled = seconds * 8_192
        guard scaled < Double(UInt16.max) else { return UInt16.max }
        return UInt16(scaled.rounded(.towardZero))
    }
}
