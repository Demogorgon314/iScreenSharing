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

    var encodedByteCount: Int { nalUnits.reduce(0) { $0 + $1.count } }

    var containsRandomAccessPicture: Bool {
        nalUnits.contains { unit in
            guard let type = AppleHEVCNALUnit.type(of: unit) else { return false }
            return (16...23).contains(type)
        }
    }
}

final class AppleHEVCStreamProcessor: @unchecked Sendable {
    private struct GroupKey: Hashable {
        let source: UInt32
        let timestamp: UInt32
        let decodingOrderNumber: UInt16?
    }

    private let lock = NSLock()
    private let decryptor: AppleSRTPDecryptor
    private var groups = [GroupKey: [AppleRTPPacket]]()
    private var sourcePacketCounts = [UInt32: Int]()
    private var sequenceTracker = AppleRTPSequenceTracker()
    private var rateControlEstimator = AppleVideoRateControlEstimator()
    private(set) var parameterSets = AppleHEVCParameterSets()

    init(keyBlob: Data) throws {
        decryptor = try AppleSRTPDecryptor(keyBlob: keyBlob)
    }

    func process(_ datagrams: [AppleReceivedVideoDatagram]) -> [AppleHEVCAccessUnit] {
        lock.withStreamLock {
            datagrams.compactMap { received -> (AppleRTPPacket, TimeInterval)? in
                guard let packet = try? decryptor.decrypt(received.data) else { return nil }
                return (packet, received.arrivalTime)
            }.compactMap {
                processUnlocked(
                    $0.0,
                    arrivalTime: $0.1,
                    packetSize: $0.0.payload.count
                )
            }
        }
    }

    func process(
        _ packet: AppleRTPPacket,
        arrivalTime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> AppleHEVCAccessUnit? {
        lock.withStreamLock {
            processUnlocked(
                packet,
                arrivalTime: arrivalTime,
                packetSize: packet.payload.count
            )
        }
    }

    private func processUnlocked(
        _ packet: AppleRTPPacket,
        arrivalTime: TimeInterval,
        packetSize: Int
    ) -> AppleHEVCAccessUnit? {
        rateControlEstimator.observe(AppleVideoPacketObservation(
            rtpTimestamp: packet.timestamp,
            arrivalTime: arrivalTime,
            packetSize: packetSize
        ))
        sequenceTracker.observe(packet, arrivalTime: arrivalTime)
        let key = GroupKey(
            source: packet.synchronizationSource,
            timestamp: packet.timestamp,
            decodingOrderNumber: AppleHEVCNALUnit.firstDecodingOrderNumber(in: [packet.payload])
        )
        sourcePacketCounts[key.source, default: 0] += 1
        var packets = groups[key, default: []]
        if !packets.contains(where: { $0.sequenceNumber == packet.sequenceNumber }) {
            packets.append(packet)
        }
        groups[key] = packets
        guard packets.contains(where: \.marker) else { return nil }
        let ordered = Self.sequenceOrdered(packets)
        guard ordered.last?.marker == true else { return nil }
        let units = AppleHEVCNALUnit.reassemble(ordered.map(\.payload))
        let isComplete = ordered.indices.dropLast().allSatisfy { index in
            ordered[index].sequenceNumber &+ 1 == ordered[index + 1].sequenceNumber
        }
        guard isComplete, !units.isEmpty else { return nil }
        groups.removeValue(forKey: key)
        harvest(units)
        return AppleHEVCAccessUnit(
            synchronizationSource: key.source,
            timestamp: key.timestamp,
            decodingOrderNumber: key.decodingOrderNumber,
            nalUnits: units
        )
    }

    func drainMissingSequences() -> [UInt32: [UInt16]] {
        lock.withStreamLock { sequenceTracker.drainMissingSequences() }
    }

    func receptionReport(for source: UInt32) -> AppleRTPReceptionReport? {
        lock.withStreamLock { sequenceTracker.receptionReport(for: source) }
    }

    func rateControlFeedback(at time: TimeInterval) -> AppleVideoRateControlInfo? {
        lock.withStreamLock { rateControlEstimator.feedback(at: time) }
    }

    func currentParameterSets() -> AppleHEVCParameterSets {
        lock.withStreamLock { parameterSets }
    }

    func reset() {
        lock.withStreamLock {
            groups.removeAll(keepingCapacity: false)
            sourcePacketCounts.removeAll(keepingCapacity: false)
            sequenceTracker = AppleRTPSequenceTracker()
            rateControlEstimator = AppleVideoRateControlEstimator()
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
    private struct ReceptionState: Sendable {
        let baseExtendedSequence: UInt32
        var maximumExtendedSequence: UInt32
        var receivedPackets: UInt32 = 1
        var previousExpectedPackets: UInt32 = 0
        var previousReceivedPackets: UInt32 = 0
        var previousTransit: Int64?
        var jitter = 0.0
    }

    private static let clockRate = 90_000.0

    private var maximumSequence = [UInt32: UInt16]()
    private var missingSequences = [UInt32: Set<UInt16>]()
    private var receptionStates = [UInt32: ReceptionState]()

    mutating func observe(
        _ packet: AppleRTPPacket,
        arrivalTime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        let source = packet.synchronizationSource
        let sequence = packet.sequenceNumber
        updateReceptionState(for: packet, arrivalTime: arrivalTime)
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

    mutating func receptionReport(for source: UInt32) -> AppleRTPReceptionReport? {
        guard var state = receptionStates[source] else { return nil }
        let expectedPackets = state.maximumExtendedSequence &- state.baseExtendedSequence &+ 1
        let cumulativeLost = Int64(expectedPackets) - Int64(state.receivedPackets)
        let expectedInterval = expectedPackets &- state.previousExpectedPackets
        let receivedInterval = state.receivedPackets &- state.previousReceivedPackets
        let lostInterval = Int64(expectedInterval) - Int64(receivedInterval)
        let fractionLost: UInt8
        if expectedInterval == 0 || lostInterval <= 0 {
            fractionLost = 0
        } else {
            fractionLost = UInt8(
                min(255, (lostInterval << 8) / Int64(expectedInterval))
            )
        }
        state.previousExpectedPackets = expectedPackets
        state.previousReceivedPackets = state.receivedPackets
        receptionStates[source] = state
        return AppleRTPReceptionReport(
            source: source,
            fractionLost: fractionLost,
            cumulativePacketsLost: Int32(
                min(max(cumulativeLost, Int64(Int32.min)), Int64(Int32.max))
            ),
            extendedHighestSequence: state.maximumExtendedSequence,
            interarrivalJitter: UInt32(max(0, state.jitter.rounded())),
            lastSenderReport: 0,
            delaySinceLastSenderReport: 0
        )
    }

    private mutating func updateReceptionState(
        for packet: AppleRTPPacket,
        arrivalTime: TimeInterval
    ) {
        let source = packet.synchronizationSource
        let arrivalTimestamp = Int64((arrivalTime * Self.clockRate).rounded())
        let transit = arrivalTimestamp - Int64(packet.timestamp)
        guard var state = receptionStates[source] else {
            receptionStates[source] = ReceptionState(
                baseExtendedSequence: UInt32(packet.sequenceNumber),
                maximumExtendedSequence: UInt32(packet.sequenceNumber),
                previousTransit: transit
            )
            return
        }

        let extendedSequence = Self.extendedSequence(
            packet.sequenceNumber,
            relativeTo: state.maximumExtendedSequence
        )
        state.maximumExtendedSequence = max(state.maximumExtendedSequence, extendedSequence)
        state.receivedPackets &+= 1
        if let previousTransit = state.previousTransit {
            let variation = abs(transit - previousTransit)
            state.jitter += (Double(variation) - state.jitter) / 16
        }
        state.previousTransit = transit
        receptionStates[source] = state
    }

    private static func extendedSequence(_ sequence: UInt16, relativeTo maximum: UInt32) -> UInt32 {
        let cycle = maximum & 0xffff_0000
        let maximumLow = UInt16(truncatingIfNeeded: maximum)
        let difference = Int(sequence) - Int(maximumLow)
        if difference < -0x8000 {
            return cycle &+ 0x1_0000 &+ UInt32(sequence)
        }
        if difference > 0x8000, cycle >= 0x1_0000 {
            return cycle &- 0x1_0000 &+ UInt32(sequence)
        }
        return cycle &+ UInt32(sequence)
    }
}

private extension NSLock {
    func withStreamLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
