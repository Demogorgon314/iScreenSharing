import Foundation

enum AppleRTCP {
    static func receiverReport(sender: UInt32) -> Data {
        var packet = Data([0x80, 201, 0, 1])
        packet.appendUInt32BE(sender)
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

    static func compound(sender: UInt32, feedback: Data) -> Data {
        receiverReport(sender: sender) + feedback
    }
}
