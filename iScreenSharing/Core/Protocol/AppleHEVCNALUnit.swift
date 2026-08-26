import Foundation

enum AppleHEVCNALUnit {
    static let videoParameterSetType: UInt8 = 32
    static let sequenceParameterSetType: UInt8 = 33
    static let pictureParameterSetType: UInt8 = 34
    static let aggregationType: UInt8 = 48
    static let fragmentationType: UInt8 = 49

    static func type(of data: Data) -> UInt8? {
        guard data.count >= 2 else { return nil }
        return (data[0] >> 1) & 0x3f
    }

    /// Matches VideoPacketBuffer's start-of-frame flag. Single NAL and
    /// aggregation packets start a frame; an FU packet only starts one when
    /// its fragmentation header carries the S bit.
    static func startsAccessUnit(_ payload: Data) -> Bool {
        guard let type = type(of: payload) else { return false }
        if type == fragmentationType {
            guard payload.count >= 5 else { return false }
            return payload[2] & 0x80 != 0
        }
        return payload.count >= 4
    }

    /// Matches the portable subset of AVConference's ReadFrameSliceHeader
    /// results that can start a high-performance bandwidth probe. Every HEVC
    /// fragmentation packet qualifies, including continuation fragments; the
    /// private frame-header signature is the other unambiguous wire form.
    static func startsBandwidthProbe(_ payload: Data) -> Bool {
        guard payload.count >= 4 else { return false }
        if payload.starts(with: [0x92, 0xe6, 0xc0, 0xa3]) {
            return true
        }
        return type(of: payload) == fragmentationType
    }

    static func reassemble(_ payloads: [Data]) -> [Data] {
        var units = [Data]()
        var fragmented = Data()
        var fragmentIsActive = false

        for payload in payloads {
            guard let type = type(of: payload) else { continue }
            switch type {
            case aggregationType:
                guard let aggregated = aggregationUnits(in: payload) else { continue }
                units.append(contentsOf: aggregated)

            case fragmentationType:
                guard payload.count >= 6 else { continue }
                let fragmentHeader = payload[2]
                let isStart = fragmentHeader & 0x80 != 0
                let isEnd = fragmentHeader & 0x40 != 0
                if isStart {
                    let innerType = fragmentHeader & 0x3f
                    fragmented = Data([
                        (payload[0] & 0x81) | (innerType << 1),
                        payload[1],
                    ])
                    fragmented.append(payload.subdata(in: 5..<payload.count))
                    fragmentIsActive = true
                    if isEnd {
                        units.append(fragmented)
                        fragmentIsActive = false
                    }
                } else if fragmentIsActive {
                    fragmented.append(payload.subdata(in: 5..<payload.count))
                    if isEnd {
                        units.append(fragmented)
                        fragmentIsActive = false
                    }
                }

            default:
                guard payload.count >= 4 else { continue }
                var unit = payload.prefix(2)
                unit.append(payload.subdata(in: 4..<payload.count))
                units.append(unit)
            }
        }
        return units
    }

    private static func aggregationUnits(in payload: Data) -> [Data]? {
        var offset = 4
        var result = [Data]()
        while offset < payload.count {
            guard payload.count - offset >= 2,
                  let length = try? Int(payload.uint16BE(at: offset)),
                  length > 0 else { return nil }
            offset += 2
            guard length <= payload.count - offset else { return nil }
            result.append(payload.subdata(in: offset..<(offset + length)))
            offset += length
        }
        return result.isEmpty ? nil : result
    }

    static func firstDecodingOrderNumber(in payloads: [Data]) -> UInt16? {
        for payload in payloads {
            guard let type = type(of: payload) else { continue }
            let offset = type == fragmentationType ? 3 : 2
            guard let value = try? payload.uint16BE(at: offset) else { continue }
            return value
        }
        return nil
    }
}
