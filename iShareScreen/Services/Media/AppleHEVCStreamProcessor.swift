import Foundation

struct AppleHEVCParameterSets: Equatable, Sendable {
    var video = Data()
    var sequence = Data()
    var pictures = [Data]()

    var isComplete: Bool { !video.isEmpty && !sequence.isEmpty && !pictures.isEmpty }
}

struct AppleHEVCAccessUnit: Equatable, Sendable {
    let synchronizationSource: UInt32
    let timestamp: UInt32
    let decodingOrderNumber: UInt16?
    let nalUnits: [Data]
}

final class AppleHEVCStreamProcessor: @unchecked Sendable {
    private struct GroupKey: Hashable {
        let source: UInt32
        let timestamp: UInt32
    }

    private let lock = NSLock()
    private let decryptor: AppleSRTPDecryptor
    private var groups = [GroupKey: [AppleRTPPacket]]()
    private var sourcePacketCounts = [UInt32: Int]()
    private var sequenceTracker = AppleRTPSequenceTracker()
    private(set) var parameterSets = AppleHEVCParameterSets()

    init(keyBlob: Data) throws {
        decryptor = try AppleSRTPDecryptor(keyBlob: keyBlob)
    }

    func process(_ datagrams: [Data]) -> [AppleHEVCAccessUnit] {
        lock.withStreamLock {
            datagrams.compactMap { try? decryptor.decrypt($0) }.compactMap(processUnlocked)
        }
    }

    func process(_ packet: AppleRTPPacket) -> AppleHEVCAccessUnit? {
        lock.withStreamLock { processUnlocked(packet) }
    }

    private func processUnlocked(_ packet: AppleRTPPacket) -> AppleHEVCAccessUnit? {
        sequenceTracker.observe(packet)
        let key = GroupKey(source: packet.synchronizationSource, timestamp: packet.timestamp)
        sourcePacketCounts[key.source, default: 0] += 1
        var packets = groups[key, default: []]
        if !packets.contains(where: { $0.sequenceNumber == packet.sequenceNumber }) {
            packets.append(packet)
        }
        groups[key] = packets
        guard packets.contains(where: \.marker) else { return nil }
        let ordered = Self.sequenceOrdered(packets)
        guard ordered.last?.marker == true else { return nil }
        groups.removeValue(forKey: key)
        let units = AppleHEVCNALUnit.reassemble(ordered.map(\.payload))
        harvest(units)
        let isComplete = ordered.indices.dropLast().allSatisfy { index in
            ordered[index].sequenceNumber &+ 1 == ordered[index + 1].sequenceNumber
        }
        guard isComplete, !units.isEmpty else { return nil }
        return AppleHEVCAccessUnit(
            synchronizationSource: key.source,
            timestamp: key.timestamp,
            decodingOrderNumber: AppleHEVCNALUnit.firstDecodingOrderNumber(
                in: ordered.map(\.payload)
            ),
            nalUnits: units
        )
    }

    func drainMissingSequences() -> [UInt32: [UInt16]] {
        lock.withStreamLock { sequenceTracker.drainMissingSequences() }
    }

    func currentParameterSets() -> AppleHEVCParameterSets {
        lock.withStreamLock { parameterSets }
    }

    func reset() {
        lock.withStreamLock {
            groups.removeAll(keepingCapacity: false)
            sourcePacketCounts.removeAll(keepingCapacity: false)
            sequenceTracker = AppleRTPSequenceTracker()
            parameterSets = AppleHEVCParameterSets()
        }
    }

    func primarySources(
        tileCount: Int,
        excluding excludedSources: Set<UInt32> = [],
        packetCountBaseline: [UInt32: Int] = [:]
    ) -> [UInt32] {
        lock.withStreamLock {
            guard tileCount > 0 else { return [] }
            let sources = sourcePacketCounts.keys.filter { !excludedSources.contains($0) }.sorted()
            var groups = [[UInt32]]()
            for source in sources {
                if let last = groups.indices.last,
                   groups[last].count < tileCount,
                   source &- groups[last].last! <= 1 {
                    groups[last].append(source)
                } else {
                    groups.append([source])
                }
            }
            return groups.max { lhs, rhs in
                let lhsRecentCount = lhs.reduce(0) { total, source in
                    total + max(0, sourcePacketCounts[source, default: 0] - packetCountBaseline[source, default: 0])
                }
                let rhsRecentCount = rhs.reduce(0) { total, source in
                    total + max(0, sourcePacketCounts[source, default: 0] - packetCountBaseline[source, default: 0])
                }
                if lhsRecentCount != rhsRecentCount { return lhsRecentCount < rhsRecentCount }
                let lhsTotalCount = lhs.reduce(0) { total, source in
                    total + sourcePacketCounts[source, default: 0]
                }
                let rhsTotalCount = rhs.reduce(0) { total, source in
                    total + sourcePacketCounts[source, default: 0]
                }
                return lhsTotalCount < rhsTotalCount
            } ?? []
        }
    }

    var packetCounts: [UInt32: Int] {
        lock.withStreamLock { sourcePacketCounts }
    }

    func packetCount(for sources: some Sequence<UInt32>) -> Int {
        lock.withStreamLock {
            sources.reduce(0) { $0 + sourcePacketCounts[$1, default: 0] }
        }
    }

    var totalPacketCount: Int {
        lock.withStreamLock { sourcePacketCounts.values.reduce(0, +) }
    }

    private func harvest(_ units: [Data]) {
        for unit in units {
            switch AppleHEVCNALUnit.type(of: unit) {
            case AppleHEVCNALUnit.videoParameterSetType:
                parameterSets.video = unit
            case AppleHEVCNALUnit.sequenceParameterSetType:
                parameterSets.sequence = unit
            case AppleHEVCNALUnit.pictureParameterSetType:
                if !parameterSets.pictures.contains(unit) { parameterSets.pictures.append(unit) }
            default:
                break
            }
        }
    }

    private static func sequenceOrdered(_ packets: [AppleRTPPacket]) -> [AppleRTPPacket] {
        let sorted = packets.sorted { $0.sequenceNumber < $1.sequenceNumber }
        guard sorted.count > 1,
              Int(sorted.last!.sequenceNumber) - Int(sorted.first!.sequenceNumber) > 0x8000 else {
            return sorted
        }
        let gaps = sorted.indices.map { index -> (Int, Int) in
            let next = sorted[(index + 1) % sorted.count].sequenceNumber
            let difference = (Int(next) - Int(sorted[index].sequenceNumber)) & 0xffff
            return (difference, index)
        }
        let gapIndex = gaps.max { $0.0 < $1.0 }!.1
        let start = (gapIndex + 1) % sorted.count
        return Array(sorted[start...]) + Array(sorted[..<start])
    }
}

struct AppleRTPSequenceTracker: Sendable {
    private var maximumSequence = [UInt32: UInt16]()
    private var missingSequences = [UInt32: Set<UInt16>]()

    mutating func observe(_ packet: AppleRTPPacket) {
        let source = packet.synchronizationSource
        let sequence = packet.sequenceNumber
        guard let previous = maximumSequence[source] else {
            maximumSequence[source] = sequence
            return
        }
        let difference = sequence &- previous
        if difference == 0 { return }
        if difference > 0x8000 {
            missingSequences[source]?.remove(sequence)
            return
        }
        if difference > 1 {
            for offset in 1..<min(Int(difference), 32) {
                missingSequences[source, default: []].insert(previous &+ UInt16(offset))
            }
        }
        maximumSequence[source] = sequence
    }

    mutating func drainMissingSequences() -> [UInt32: [UInt16]] {
        defer { missingSequences.removeAll(keepingCapacity: true) }
        return missingSequences.mapValues { $0.sorted() }
    }
}

private extension NSLock {
    func withStreamLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
