import Foundation

struct AppleHEVCDecodingOrderQueue {
    struct Output {
        let ready: [AppleHEVCAccessUnit]
        let requiresRefresh: Bool
    }

    private let maximumPendingCount: Int
    private var expectedDecodingOrderNumber: UInt16?
    private var pending = [UInt16: AppleHEVCAccessUnit]()

    init(maximumPendingCount: Int = 8) {
        precondition(maximumPendingCount > 0)
        self.maximumPendingCount = maximumPendingCount
    }

    mutating func enqueue(_ accessUnits: [AppleHEVCAccessUnit]) -> Output {
        var ready = accessUnits.filter { $0.decodingOrderNumber == nil }
        let orderedUnits = accessUnits.filter { $0.decodingOrderNumber != nil }

        if expectedDecodingOrderNumber == nil, !orderedUnits.isEmpty {
            let bootstrap = Self.circularlyOrdered(orderedUnits)
            expectedDecodingOrderNumber = bootstrap.first?.decodingOrderNumber
            insert(bootstrap)
        } else {
            insert(orderedUnits)
        }

        ready.append(contentsOf: drainReady())
        guard pending.count <= maximumPendingCount else {
            reset()
            return Output(ready: ready.filter { $0.decodingOrderNumber == nil }, requiresRefresh: true)
        }
        return Output(ready: ready, requiresRefresh: false)
    }

    mutating func reset() {
        expectedDecodingOrderNumber = nil
        pending.removeAll(keepingCapacity: false)
    }

    private mutating func insert(_ accessUnits: [AppleHEVCAccessUnit]) {
        for accessUnit in accessUnits {
            guard let decodingOrderNumber = accessUnit.decodingOrderNumber,
                  let expectedDecodingOrderNumber else { continue }
            let distance = decodingOrderNumber &- expectedDecodingOrderNumber
            guard distance <= 0x7ffe else { continue }
            pending[decodingOrderNumber] = accessUnit
        }
    }

    private mutating func drainReady() -> [AppleHEVCAccessUnit] {
        var ready = [AppleHEVCAccessUnit]()
        while let expectedDecodingOrderNumber,
              let accessUnit = pending.removeValue(forKey: expectedDecodingOrderNumber) {
            ready.append(accessUnit)
            self.expectedDecodingOrderNumber = expectedDecodingOrderNumber &+ 1
        }
        return ready
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
