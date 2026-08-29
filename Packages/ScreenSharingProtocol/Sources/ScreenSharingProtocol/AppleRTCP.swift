import Foundation

/// Reception statistics carried by an RTCP receiver report block.
public struct AppleRTPReceptionReport: Equatable, Sendable {
    public let source: UInt32
    public let fractionLost: UInt8
    public let cumulativePacketsLost: Int32
    public let extendedHighestSequence: UInt32
    public let interarrivalJitter: UInt32
    public let lastSenderReport: UInt32
    public let delaySinceLastSenderReport: UInt32

    public init(
        source: UInt32,
        fractionLost: UInt8,
        cumulativePacketsLost: Int32,
        extendedHighestSequence: UInt32,
        interarrivalJitter: UInt32,
        lastSenderReport: UInt32,
        delaySinceLastSenderReport: UInt32
    ) {
        self.source = source
        self.fractionLost = fractionLost
        self.cumulativePacketsLost = cumulativePacketsLost
        self.extendedHighestSequence = extendedHighestSequence
        self.interarrivalJitter = interarrivalJitter
        self.lastSenderReport = lastSenderReport
        self.delaySinceLastSenderReport = delaySinceLastSenderReport
    }
}

/// Deterministic encoders for the RTCP packets used by High-Performance Mode.
public enum AppleRTCP {
    public static func receiverReport(sender: UInt32) -> Data {
        var packet = Data([0x80, 201, 0, 1])
        BigEndianWire.append(sender, to: &packet)
        return packet
    }

    public static func receiverReport(sender: UInt32, report: AppleRTPReceptionReport) -> Data {
        var packet = Data([0x81, 201, 0, 7])
        BigEndianWire.append(sender, to: &packet)
        BigEndianWire.append(report.source, to: &packet)
        packet.append(report.fractionLost)
        packet.appendSigned24BE(report.cumulativePacketsLost)
        BigEndianWire.append(report.extendedHighestSequence, to: &packet)
        BigEndianWire.append(report.interarrivalJitter, to: &packet)
        BigEndianWire.append(report.lastSenderReport, to: &packet)
        BigEndianWire.append(report.delaySinceLastSenderReport, to: &packet)
        return packet
    }

    public static func genericNACK(
        sender: UInt32,
        mediaSource: UInt32,
        lostSequences: some Sequence<UInt16>
    ) -> Data {
        let sequences = Array(Set(lostSequences)).sorted()
        guard !sequences.isEmpty else { return Data() }

        var feedback = Data()
        var index = 0
        while index < sequences.count {
            let packetID = sequences[index]
            var bitmask: UInt16 = 0
            var next = index + 1
            while next < sequences.count {
                let difference = sequences[next] &- packetID
                guard difference >= 1, difference <= 16 else { break }
                bitmask |= UInt16(1) << (difference - 1)
                next += 1
            }
            BigEndianWire.append(packetID, to: &feedback)
            BigEndianWire.append(bitmask, to: &feedback)
            index = next
        }

        var packet = Data([0x81, 205])
        BigEndianWire.append(UInt16(2 + feedback.count / 4), to: &packet)
        BigEndianWire.append(sender, to: &packet)
        BigEndianWire.append(mediaSource, to: &packet)
        packet.append(feedback)
        return packet
    }

    public static func fullIntraRequest(
        sender: UInt32,
        mediaSource: UInt32,
        sequence: UInt8
    ) -> Data {
        var packet = Data([0x84, 206, 0, 4])
        BigEndianWire.append(sender, to: &packet)
        BigEndianWire.append(UInt32(0), to: &packet)
        BigEndianWire.append(mediaSource, to: &packet)
        packet.append(sequence)
        packet.append(contentsOf: [0, 0, 0])
        return packet
    }

    public static func frameLossFeedback(
        sender: UInt32,
        mediaSource: UInt32,
        rtpTimestamp: UInt32,
        packedLoss: UInt16,
        framePacketCount: UInt8,
        frameLostPacketCount: UInt8
    ) -> Data {
        var packet = Data([0x8f, 206, 0, 5])
        BigEndianWire.append(sender, to: &packet)
        BigEndianWire.append(mediaSource, to: &packet)
        BigEndianWire.append(UInt32(6), to: &packet)
        BigEndianWire.append(rtpTimestamp, to: &packet)
        BigEndianWire.append(packedLoss, to: &packet)
        packet.append(framePacketCount)
        packet.append(frameLostPacketCount)
        return packet
    }

    public static func longTermReferenceAcknowledgement(
        sender: UInt32,
        decodingOrderNumber: UInt16
    ) -> Data {
        var packet = Data([0x80, 204, 0, 3])
        BigEndianWire.append(sender, to: &packet)
        BigEndianWire.append(UInt32(5), to: &packet)
        BigEndianWire.append(UInt32(decodingOrderNumber), to: &packet)
        return packet
    }

    public static func rateControl(sender: UInt32, mediaControlInfo: Data) -> Data {
        guard mediaControlInfo.count == 20 else { return Data() }
        var packet = Data([0x80, 204, 0, 7])
        BigEndianWire.append(sender, to: &packet)
        packet.append(contentsOf: [0x52, 0x43, 0x54, 0x4c])
        packet.append(mediaControlInfo)
        return packet
    }

    public static func compound(sender: UInt32, feedback: Data) -> Data {
        receiverReport(sender: sender) + feedback
    }
}

private extension Data {
    mutating func appendSigned24BE(_ value: Int32) {
        let clamped = Swift.min(Swift.max(value, -0x80_0000), 0x7f_ffff)
        let bits = UInt32(bitPattern: clamped) & 0x00ff_ffff
        append(UInt8(truncatingIfNeeded: bits >> 16))
        append(UInt8(truncatingIfNeeded: bits >> 8))
        append(UInt8(truncatingIfNeeded: bits))
    }
}
