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

    static func reassemble(_ payloads: [Data]) -> [Data] {
        var units = [Data]()
        var fragmented = Data()
        var fragmentIsActive = false

        for payload in payloads {
            guard let type = type(of: payload) else { continue }
            switch type {
            case aggregationType:
                var offset = 4
                while offset + 2 <= payload.count {
                    guard let length = try? Int(payload.uint16BE(at: offset)),
                          length > 0,
                          offset + 2 + length <= payload.count else { break }
                    offset += 2
                    units.append(payload.subdata(in: offset..<(offset + length)))
                    offset += length
                }

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
}
