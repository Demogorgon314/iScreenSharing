import Foundation

/// Reads the end-of-data control bit carried by Apple's FLS HEVC suffix.
/// This contract was confirmed against VideoProcessing on macOS 15.7.7
/// (24G720); the parser itself uses no private API.
/// A malformed or unsupported suffix is deliberately reported as unknown so
/// callers can retain their sequence-advance fallback.
struct AppleHEVCSubframeBoundaryParser: Sendable {
    enum Boundary: Equatable, Sendable {
        case notLast
        case last
        case unknown
    }

    private let endOfDataBit: UInt8

    init?(negotiationDetails: String) {
        let fields = negotiationDetails.split(separator: ";")
        guard fields.contains("FLS"),
              let endOfData = fields.first(where: { $0.hasPrefix("EOD:") }),
              let bit = UInt8(endOfData.dropFirst(4)),
              bit < 7 else {
            return nil
        }
        endOfDataBit = bit
    }

    func classify(nalUnits: [Data]) -> Boundary {
        guard let unit = nalUnits.last(where: Self.isVCLNALUnit),
              let controlByte = Self.flsControlByte(in: unit) else {
            return .unknown
        }
        return controlByte & (1 << endOfDataBit) == 0 ? .notLast : .last
    }

    private static func isVCLNALUnit(_ unit: Data) -> Bool {
        guard let type = AppleHEVCNALUnit.type(of: unit) else { return false }
        return type <= 31
    }

    private static func flsControlByte(in unit: Data) -> UInt8? {
        guard unit.count > 2 else { return nil }
        var rbsp = [UInt8]()
        rbsp.reserveCapacity(unit.count - 2)
        var zeroCount = 0

        for byte in unit.dropFirst(2) {
            if zeroCount >= 2, byte == 0x03 {
                zeroCount = 0
                continue
            }
            rbsp.append(byte)
            zeroCount = byte == 0 ? zeroCount + 1 : 0
        }
        guard let last = rbsp.last else { return nil }
        // FLS uses the high bit as its terminal marker. VCP clears that bit
        // before dispatching the suffix to its control-field parser.
        return last & 0x7f
    }
}
