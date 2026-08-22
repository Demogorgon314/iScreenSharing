import Foundation

struct AppleRTPReceptionReport: Equatable, Sendable {
    let source: UInt32
    let fractionLost: UInt8
    let cumulativePacketsLost: Int32
    let extendedHighestSequence: UInt32
    let interarrivalJitter: UInt32
    let lastSenderReport: UInt32
    let delaySinceLastSenderReport: UInt32
}

enum AppleRTCP {
    static func receiverReport(sender: UInt32) -> Data {
        var packet = Data([0x80, 201, 0, 1])
        packet.appendUInt32BE(sender)
        return packet
    }

    static func receiverReport(sender: UInt32, report: AppleRTPReceptionReport) -> Data {
        var packet = Data([0x81, 201, 0, 7])
        packet.appendUInt32BE(sender)
        packet.appendUInt32BE(report.source)
        packet.append(report.fractionLost)
        packet.appendSigned24BE(report.cumulativePacketsLost)
        packet.appendUInt32BE(report.extendedHighestSequence)
        packet.appendUInt32BE(report.interarrivalJitter)
        packet.appendUInt32BE(report.lastSenderReport)
        packet.appendUInt32BE(report.delaySinceLastSenderReport)
        return packet
    }

    static func genericNACK(sender: UInt32, mediaSource: UInt32, lostSequences: some Sequence<UInt16>) -> Data {
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
            feedback.appendUInt16BE(packetID)
            feedback.appendUInt16BE(bitmask)
            index = next
        }

        var packet = Data([0x81, 205])
        packet.appendUInt16BE(UInt16(2 + feedback.count / 4))
        packet.appendUInt32BE(sender)
        packet.appendUInt32BE(mediaSource)
        packet.append(feedback)
        return packet
    }

    static func fullIntraRequest(sender: UInt32, mediaSource: UInt32, sequence: UInt8) -> Data {
        var packet = Data([0x84, 206, 0, 4])
        packet.appendUInt32BE(sender)
        packet.appendUInt32BE(0)
        packet.appendUInt32BE(mediaSource)
        packet.append(sequence)
        packet.append(contentsOf: [0, 0, 0])
        return packet
    }

    static func pictureLossIndication(sender: UInt32, mediaSource: UInt32) -> Data {
        var packet = Data([0x81, 206, 0, 2])
        packet.appendUInt32BE(sender)
        packet.appendUInt32BE(mediaSource)
        return packet
    }

    static func legacyFullIntraRequest(mediaSource: UInt32) -> Data {
        var packet = Data([0x80, 192, 0, 1])
        packet.appendUInt32BE(mediaSource)
        return packet
    }

    static func longTermReferenceAcknowledgement(sender: UInt32, frameID: UInt16) -> Data {
        var packet = Data([0x80, 204, 0, 3])
        packet.appendUInt32BE(sender)
        packet.appendUInt32BE(5)
        packet.appendUInt32BE(UInt32(frameID))
        return packet
    }

    static func rateControl(sender: UInt32, mediaControlInfo: Data) -> Data {
        guard mediaControlInfo.count == 20 else { return Data() }
        var packet = Data([0x80, 204, 0, 7])
        packet.appendUInt32BE(sender)
        packet.append(contentsOf: [0x52, 0x43, 0x54, 0x4c]) // "RCTL"
        packet.append(mediaControlInfo)
        return packet
    }

    static func compound(sender: UInt32, feedback: Data) -> Data {
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
