import Foundation
import QuartzCore

struct AppleHEVCParameterSets: Equatable, Sendable {
    var video = Data()
    var sequence = Data()
    var pictures = [Data]()

    var isComplete: Bool { !video.isEmpty && !sequence.isEmpty && !pictures.isEmpty }
}

struct AppleHEVCAccessUnit: Equatable, Sendable {
    struct Timing: Equatable, Sendable {
        let traceSequence: UInt64
        let firstDatagramObservedAt: TimeInterval
        let completingDatagramObservedAt: TimeInterval
        let assemblyCompletedAt: TimeInterval
    }

    let synchronizationSource: UInt32
    let timestamp: UInt32
    let decodingOrderNumber: UInt16?
    let nalUnits: [Data]
    let isLongTermReferenceFrame: Bool
    let timing: Timing?

    init(
        synchronizationSource: UInt32,
        timestamp: UInt32,
        decodingOrderNumber: UInt16?,
        nalUnits: [Data],
        isLongTermReferenceFrame: Bool = false,
        timing: Timing? = nil
    ) {
        self.synchronizationSource = synchronizationSource
        self.timestamp = timestamp
        self.decodingOrderNumber = decodingOrderNumber
        self.nalUnits = nalUnits
        self.isLongTermReferenceFrame = isLongTermReferenceFrame
        self.timing = timing
    }

    var encodedByteCount: Int { nalUnits.reduce(0) { $0 + $1.count } }

    var containsRandomAccessPicture: Bool {
        nalUnits.contains { unit in
            guard let type = AppleHEVCNALUnit.type(of: unit) else { return false }
            return (16...23).contains(type)
        }
    }
}

struct AppleVideoFrameLossFeedback: Equatable, Sendable {
    let mediaSource: UInt32
    let rtpTimestamp: UInt32
    let expectedPacketCount: UInt16
    let lostPacketCount: UInt16

    var packedLoss: UInt16 {
        ((expectedPacketCount & 0x3f) << 6) | (lostPacketCount & 0x3f)
    }

    var wirePacketCount: UInt8 { UInt8(truncatingIfNeeded: expectedPacketCount) }
    var wireLostPacketCount: UInt8 { UInt8(truncatingIfNeeded: lostPacketCount) }
}

final class AppleHEVCStreamProcessor: @unchecked Sendable {
    private static let rtpClockRate: UInt32 = 24_000
    private static let maximumIncompleteTimestampDelta = rtpClockRate / 2
    private static let maximumIncompleteAge: TimeInterval = 0.5
    private static let frameLossFeedbackRepeatInterval: TimeInterval = 0.1

    private struct GroupKey: Hashable {
        let source: UInt32
        let timestamp: UInt32
    }

    private struct PendingAccessUnit {
        var firstSeenAt: TimeInterval?
        var decodingOrderNumber: UInt16?
        var framePacketInfo: AppleRTPFramePacketInfo?
        var isLongTermReferenceFrame = false
        var packets = [AppleRTPPacket]()
    }

    private struct CachedFrameLoss {
        let rtpTimestamp: UInt32
        let frameSequenceNumber: UInt16
        let expectedPacketCount: UInt16
        var receivedSequences: Set<UInt16>
        var lastSentAt: TimeInterval?

        var lostPacketCount: UInt16 {
            UInt16(max(0, Int(expectedPacketCount) - receivedSequences.count))
        }
    }

    private let lock = NSLock()
    private let decryptor: AppleSRTPDecryptor
    private let clock: @Sendable () -> TimeInterval
    private var groups = [GroupKey: PendingAccessUnit]()
    private var sourcePacketCounts = [UInt32: Int]()
    private var sequenceTracker = AppleRTPSequenceTracker()
    private var rateControlEstimator = AppleVideoRateControlEstimator()
    private var bandwidthProbeGate = AppleVideoBandwidthProbeGate()
    private var playoutTimestamp: UInt32?
    private var cachedFrameLosses = [UInt32: CachedFrameLoss]()
    private var nextAccessUnitTraceSequence: UInt64 = 0
    private(set) var parameterSets = AppleHEVCParameterSets()

    init(
        keyBlob: Data,
        clock: @escaping @Sendable () -> TimeInterval = { CACurrentMediaTime() }
    ) throws {
        decryptor = try AppleSRTPDecryptor(keyBlob: keyBlob)
        self.clock = clock
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

    func process(_ datagram: AppleReceivedVideoDatagram) -> AppleHEVCAccessUnit? {
        lock.withStreamLock {
            guard let packet = try? decryptor.decrypt(datagram.data) else { return nil }
            return processUnlocked(
                packet,
                arrivalTime: datagram.arrivalTime,
                packetSize: packet.payload.count
            )
        }
    }

    func process(
        _ packet: AppleRTPPacket,
        arrivalTime: TimeInterval = CACurrentMediaTime()
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
        let observation = AppleVideoPacketObservation(
            rtpTimestamp: packet.timestamp,
            arrivalTime: arrivalTime,
            packetSize: packetSize
        )
        let bandwidthProbeActivity = bandwidthProbeGate.classify(
            timestamp: packet.timestamp,
            arrivalTime: arrivalTime,
            isEndOfFrame: packet.marker,
            payload: packet.payload
        )
        rateControlEstimator.observe(
            observation,
            bandwidthProbeActivity: bandwidthProbeActivity
        )
        sequenceTracker.observe(packet, arrivalTime: arrivalTime)
        correctCachedFrameLoss(with: packet)
        let key = GroupKey(
            source: packet.synchronizationSource,
            timestamp: packet.timestamp
        )
        let packetDecodingOrderNumber = AppleHEVCNALUnit.firstDecodingOrderNumber(
            in: [packet.payload]
        )
        let packetFrameInfo = packet.framePacketInfo
        sourcePacketCounts[key.source, default: 0] += 1
        var group = groups[key, default: PendingAccessUnit()]
        if group.firstSeenAt == nil {
            group.firstSeenAt = arrivalTime
            group.isLongTermReferenceFrame = packet.isLongTermReferenceFrame
        }
        if let existing = group.decodingOrderNumber,
           let packetDecodingOrderNumber,
           packetDecodingOrderNumber != existing {
            groups[key] = group
            advancePlayoutTimestamp(to: packet.timestamp)
            evictStaleIncompleteAccessUnits(at: arrivalTime)
            return nil
        }
        if group.decodingOrderNumber == nil {
            group.decodingOrderNumber = packetDecodingOrderNumber
        }
        if let existing = group.framePacketInfo,
           let packetFrameInfo,
           packetFrameInfo != existing {
            groups[key] = group
            advancePlayoutTimestamp(to: packet.timestamp)
            evictStaleIncompleteAccessUnits(at: arrivalTime)
            return nil
        }
        if group.framePacketInfo == nil {
            group.framePacketInfo = packetFrameInfo
        }
        if !group.packets.contains(where: { $0.sequenceNumber == packet.sequenceNumber }) {
            group.packets.append(packet)
        }
        groups[key] = group
        advancePlayoutTimestamp(to: packet.timestamp)
        evictStaleIncompleteAccessUnits(at: arrivalTime)
        guard group.packets.contains(where: \.marker) else { return nil }
        let ordered = Self.sequenceOrdered(group.packets)
        guard ordered.last?.marker == true,
              let firstPacket = ordered.first,
              AppleHEVCNALUnit.startsAccessUnit(firstPacket.payload) else { return nil }
        let units = AppleHEVCNALUnit.reassemble(ordered.map(\.payload))
        let isComplete = ordered.indices.dropLast().allSatisfy { index in
            ordered[index].sequenceNumber &+ 1 == ordered[index + 1].sequenceNumber
        }
        guard isComplete, !units.isEmpty else { return nil }
        groups.removeValue(forKey: key)
        cacheFrameLossIfNeeded(for: key, group: group)
        harvest(units)
        nextAccessUnitTraceSequence &+= 1
        return AppleHEVCAccessUnit(
            synchronizationSource: key.source,
            timestamp: key.timestamp,
            decodingOrderNumber: group.decodingOrderNumber,
            nalUnits: units,
            isLongTermReferenceFrame: group.isLongTermReferenceFrame,
            timing: AppleHEVCAccessUnit.Timing(
                traceSequence: nextAccessUnitTraceSequence,
                firstDatagramObservedAt: group.firstSeenAt ?? arrivalTime,
                completingDatagramObservedAt: arrivalTime,
                assemblyCompletedAt: clock()
            )
        )
    }

    func missingSequencesDueForNACK(at time: TimeInterval) -> [UInt32: [UInt16]] {
        lock.withStreamLock { sequenceTracker.missingSequencesDueForNACK(at: time) }
    }

    func markNACKsSent(_ sequences: [UInt32: [UInt16]], at time: TimeInterval) {
        lock.withStreamLock { sequenceTracker.markNACKsSent(sequences, at: time) }
    }

    func receptionReport(for source: UInt32) -> AppleRTPReceptionReport? {
        lock.withStreamLock { sequenceTracker.receptionReport(for: source) }
    }

    func rateControlFeedback(at time: TimeInterval) -> AppleVideoRateControlInfo? {
        lock.withStreamLock { rateControlEstimator.feedback(at: time) }
    }

    func rateControlDiagnostics() -> AppleVideoRateControlDiagnostics {
        lock.withStreamLock { rateControlEstimator.diagnostics }
    }

    func frameLossFeedbackDue(at time: TimeInterval) -> [AppleVideoFrameLossFeedback] {
        lock.withStreamLock {
            var feedback = [AppleVideoFrameLossFeedback]()
            for source in cachedFrameLosses.keys.sorted() {
                guard let loss = cachedFrameLosses[source], loss.lostPacketCount > 0 else {
                    cachedFrameLosses.removeValue(forKey: source)
                    continue
                }
                if let lastSentAt = loss.lastSentAt,
                   time - lastSentAt < Self.frameLossFeedbackRepeatInterval {
                    continue
                }
                feedback.append(AppleVideoFrameLossFeedback(
                    mediaSource: source,
                    rtpTimestamp: loss.rtpTimestamp,
                    expectedPacketCount: loss.expectedPacketCount,
                    lostPacketCount: loss.lostPacketCount
                ))
            }
            return feedback
        }
    }

    func markFrameLossFeedbackSent(
        _ feedback: AppleVideoFrameLossFeedback,
        at time: TimeInterval
    ) {
        lock.withStreamLock {
            guard var loss = cachedFrameLosses[feedback.mediaSource],
                  loss.rtpTimestamp == feedback.rtpTimestamp else { return }
            loss.lastSentAt = time
            cachedFrameLosses[feedback.mediaSource] = loss
        }
    }

    func currentParameterSets() -> AppleHEVCParameterSets {
        lock.withStreamLock { parameterSets }
    }

    var currentPlayoutTimestamp: UInt32? {
        lock.withStreamLock { playoutTimestamp }
    }

    func discardBufferedAccessUnits() {
        lock.withStreamLock {
            groups.removeAll(keepingCapacity: false)
        }
    }

    func expireIncompleteAccessUnits(at time: TimeInterval) {
        lock.withStreamLock {
            evictStaleIncompleteAccessUnits(at: time)
        }
    }

    func reset() {
        lock.withStreamLock {
            groups.removeAll(keepingCapacity: false)
            sourcePacketCounts.removeAll(keepingCapacity: false)
            sequenceTracker = AppleRTPSequenceTracker()
            rateControlEstimator = AppleVideoRateControlEstimator()
            bandwidthProbeGate = AppleVideoBandwidthProbeGate()
            playoutTimestamp = nil
            cachedFrameLosses.removeAll(keepingCapacity: false)
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

    private func advancePlayoutTimestamp(to timestamp: UInt32) {
        guard let playoutTimestamp else {
            self.playoutTimestamp = timestamp
            return
        }
        let delta = timestamp &- playoutTimestamp
        if delta > 0, delta <= 0x7fff_ffff {
            self.playoutTimestamp = timestamp
        }
    }

    private func evictStaleIncompleteAccessUnits(at time: TimeInterval) {
        groups = groups.filter { key, group in
            let isWithinHostTimeWindow: Bool
            if let firstSeenAt = group.firstSeenAt {
                let age = time - firstSeenAt
                isWithinHostTimeWindow = age < 0 || age <= Self.maximumIncompleteAge
            } else {
                isWithinHostTimeWindow = true
            }
            guard isWithinHostTimeWindow, let playoutTimestamp else {
                return isWithinHostTimeWindow
            }
            let delta = playoutTimestamp &- key.timestamp
            return delta > 0x7fff_ffff || delta <= Self.maximumIncompleteTimestampDelta
        }
    }

    private func cacheFrameLossIfNeeded(for key: GroupKey, group: PendingAccessUnit) {
        guard let info = group.framePacketInfo,
              Int(info.totalPacketsPerFrame) > group.packets.count else { return }
        cachedFrameLosses[key.source] = CachedFrameLoss(
            rtpTimestamp: key.timestamp,
            frameSequenceNumber: info.frameSequenceNumber,
            expectedPacketCount: info.totalPacketsPerFrame,
            receivedSequences: Set(group.packets.map(\.sequenceNumber)),
            lastSentAt: nil
        )
    }

    private func correctCachedFrameLoss(with packet: AppleRTPPacket) {
        let source = packet.synchronizationSource
        guard var loss = cachedFrameLosses[source],
              loss.rtpTimestamp == packet.timestamp,
              let info = packet.framePacketInfo,
              info.frameSequenceNumber == loss.frameSequenceNumber,
              info.totalPacketsPerFrame == loss.expectedPacketCount else { return }
        loss.receivedSequences.insert(packet.sequenceNumber)
        if loss.lostPacketCount == 0 {
            cachedFrameLosses.removeValue(forKey: source)
        } else {
            cachedFrameLosses[source] = loss
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
    private struct MissingPacket: Sendable {
        let firstDetectedAt: TimeInterval
        var lastNACKAt: TimeInterval?
    }

    private struct ReceptionState: Sendable {
        let baseExtendedSequence: UInt32
        var maximumExtendedSequence: UInt32
        var receivedPackets: UInt32 = 1
        var previousExpectedPackets: UInt32 = 0
        var previousReceivedPackets: UInt32 = 0
        var previousTransit: Int64?
        var jitter = 0.0
    }

    private static let clockRate = 24_000.0
    private static let recentMissingPacketLimit = 17
    private static let nackRetryInterval = 0.150
    private static let missingPacketLifetime = 1.0

    private var maximumSequence = [UInt32: UInt16]()
    private var missingPackets = [UInt32: [UInt16: MissingPacket]]()
    private var receptionStates = [UInt32: ReceptionState]()

    mutating func observe(
        _ packet: AppleRTPPacket,
        arrivalTime: TimeInterval = CACurrentMediaTime()
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
            missingPackets[source]?.removeValue(forKey: sequence)
            if missingPackets[source]?.isEmpty == true {
                missingPackets.removeValue(forKey: source)
            }
            return
        }
        if difference > 1 {
            let differenceCount = Int(difference)
            let trackedCount = min(differenceCount - 1, Self.recentMissingPacketLimit)
            let firstOffset = differenceCount - trackedCount
            for offset in firstOffset..<differenceCount {
                let missingSequence = previous &+ UInt16(offset)
                if missingPackets[source]?[missingSequence] == nil {
                    missingPackets[source, default: [:]][missingSequence] = MissingPacket(
                        firstDetectedAt: arrivalTime,
                        lastNACKAt: nil
                    )
                }
            }
        }
        maximumSequence[source] = sequence
    }

    mutating func missingSequencesDueForNACK(at time: TimeInterval) -> [UInt32: [UInt16]] {
        var due = [UInt32: [UInt16]]()
        for source in Array(missingPackets.keys) {
            guard var packets = missingPackets[source] else { continue }
            packets = packets.filter {
                time - $0.value.firstDetectedAt <= Self.missingPacketLifetime
            }
            if packets.isEmpty {
                missingPackets.removeValue(forKey: source)
                continue
            }
            missingPackets[source] = packets
            let sequences = packets.compactMap { sequence, packet -> UInt16? in
                guard let lastNACKAt = packet.lastNACKAt else { return sequence }
                return time - lastNACKAt > Self.nackRetryInterval ? sequence : nil
            }.sorted()
            if !sequences.isEmpty {
                due[source] = sequences
            }
        }
        return due
    }

    mutating func markNACKsSent(
        _ sequencesBySource: [UInt32: [UInt16]],
        at time: TimeInterval
    ) {
        for (source, sequences) in sequencesBySource {
            guard var packets = missingPackets[source] else { continue }
            for sequence in sequences where packets[sequence] != nil {
                packets[sequence]?.lastNACKAt = time
            }
            missingPackets[source] = packets
        }
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
