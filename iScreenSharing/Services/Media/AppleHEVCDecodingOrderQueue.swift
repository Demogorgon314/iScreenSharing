import Foundation

/// Applies the receiver's wrap-safe DON admission. Complete forward subframes
/// are never held waiting for a missing DON; late subframes are discarded.
struct AppleHEVCDecodingOrderQueue {
    struct Output {
        let accessUnits: [AppleHEVCAccessUnit]
    }

    private var expectedDecodingOrderNumber: UInt16?

    mutating func enqueue(
        _ accessUnits: [AppleHEVCAccessUnit]
    ) -> Output {
        var ready = accessUnits.filter { $0.decodingOrderNumber == nil }
        let receivedUnits = accessUnits.filter { $0.decodingOrderNumber != nil }
        let orderedUnits = expectedDecodingOrderNumber == nil
            ? Self.circularlyOrdered(receivedUnits)
            : receivedUnits

        for accessUnit in orderedUnits {
            guard let order = accessUnit.decodingOrderNumber else { continue }
            if let expectedDecodingOrderNumber {
                let delta = order &- expectedDecodingOrderNumber
                guard delta <= 0x7ffe else { continue }
            }
            ready.append(accessUnit)
            expectedDecodingOrderNumber = order &+ 1
        }
        return Output(accessUnits: ready)
    }

    mutating func reset() {
        expectedDecodingOrderNumber = nil
    }

    private static func circularlyOrdered(
        _ accessUnits: [AppleHEVCAccessUnit]
    ) -> [AppleHEVCAccessUnit] {
        let sorted = accessUnits.sorted {
            $0.decodingOrderNumber! < $1.decodingOrderNumber!
        }
        guard sorted.count > 1 else { return sorted }

        let largestGapIndex = sorted.indices.max { lhs, rhs in
            let lhsNext = sorted[(lhs + 1) % sorted.count].decodingOrderNumber!
            let rhsNext = sorted[(rhs + 1) % sorted.count].decodingOrderNumber!
            let lhsGap = lhsNext &- sorted[lhs].decodingOrderNumber!
            let rhsGap = rhsNext &- sorted[rhs].decodingOrderNumber!
            return lhsGap < rhsGap
        }!
        let start = (largestGapIndex + 1) % sorted.count
        return Array(sorted[start...]) + Array(sorted[..<start])
    }
}
