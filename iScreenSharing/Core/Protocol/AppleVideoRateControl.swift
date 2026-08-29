import Foundation

struct AppleVideoPacketObservation: Equatable, Sendable {
    let rtpTimestamp: UInt32
    let arrivalTime: TimeInterval
    let packetSize: Int
}

struct AppleVideoRateControlDiagnostics: Equatable, Sendable {
    let candidateBandwidthMegabitsPerSecond: Double
    let probeDurationMilliseconds: Double
    let probeBytesAfterReference: UInt64
    let timestampDelta: UInt32
    let estimateState: String
    let pendingSampleCount: Int
}

enum AppleVideoBandwidthProbeActivity: Equatable, Sendable {
    case active
    case boundary
    case suppressed
}

struct AppleVideoBandwidthProbeGate: Sendable {
    private static let cooldown: TimeInterval = 2

    private var activeTimestamp: UInt32?
    private var lastProbeEnd: TimeInterval?

    mutating func classify(
        timestamp: UInt32,
        arrivalTime: TimeInterval,
        isEndOfFrame: Bool,
        payload: Data
    ) -> AppleVideoBandwidthProbeActivity {
        if let lastProbeEnd,
           arrivalTime - lastProbeEnd < Self.cooldown {
            return .suppressed
        }

        let isActive: Bool
        if AppleHEVCNALUnit.startsBandwidthProbe(payload) {
            activeTimestamp = timestamp
            isActive = true
        } else if activeTimestamp == timestamp {
            isActive = true
        } else {
            activeTimestamp = nil
            isActive = false
        }

        if isEndOfFrame || !isActive {
            lastProbeEnd = arrivalTime
        }
        return isActive ? .active : .boundary
    }
}

enum AppleVideoRateControlMode: Equatable, Sendable {
    case estimated
    case fixedLAN
    case disabled

    init(environmentValue: String?) {
        switch environmentValue?.lowercased() {
        case "fixed-lan": self = .fixedLAN
        case "disabled": self = .disabled
        default: self = .estimated
        }
    }

    func apply(to info: AppleVideoRateControlInfo) -> AppleVideoRateControlInfo? {
        switch self {
        case .estimated:
            return info
        case .fixedLAN:
            return AppleVideoRateControlInfo(
                rtpTimestamp: info.rtpTimestamp,
                estimatedBandwidthKilobitsPerSecond: 60_001,
                burstyLoss: info.burstyLoss,
                receivedPacketCount: info.receivedPacketCount,
                feedbackDelayMilliseconds: info.feedbackDelayMilliseconds,
                echoTimestamp: info.echoTimestamp,
                oneWayReceiveDelay: info.oneWayReceiveDelay
            )
        case .disabled:
            return nil
        }
    }
}

struct AppleVideoRateControlEstimator: Sendable {
    private enum EstimateState: String, Sendable {
        case initial
        case stable
        case insufficientProbeWindow
        case pendingUp
        case pendingDown
        case committed
    }

    private struct ProbeGroup: Sendable {
        let timestamp: UInt32
        let referenceArrival: TimeInterval
        var lastArrival: TimeInterval
        var bytesAfterReference: UInt64 = 0
        var packetsAfterReference = 0
    }

    private static let defaultHighPerformanceTimestampRate: UInt32 = 24_000
    private static let maximumBandwidth = 60_000_000.0
    private static let minimumProbeBytes: UInt64 = 250
    private static let minimumProbeDuration: TimeInterval = 0.008
    private static let shortProbeConfirmationCount = 3
    private static let suddenChangeMargin = 200_000.0
    private static let suddenChangePercentage = 0.5
    private static let suddenChangeSamples = 3

    private var probeGroup: ProbeGroup?
    private var estimatedBandwidth: Double?
    private var estimateState = EstimateState.stable
    private var pendingDirection = 0
    private var pendingBandwidth = 0.0
    private var pendingCount = 0
    private var consecutiveShortProbeCount = 0
    private var lastCandidateBandwidth = 0.0
    private var lastProbeDuration = 0.0
    private var lastProbeBytesAfterReference: UInt64 = 0
    private var lastTimestampDelta: UInt32 = 0

    private var didReceiveVideo = false
    private var totalPacketsReceived: UInt32 = 0
    private var previousTimestamp: UInt32?
    private var lastAcceptedTimestamp: UInt32 = 0
    private var lastAcceptedPacketCount: UInt32 = 0
    private var lastAcceptedArrival: TimeInterval?

    private var delayPreviousTimestamp: UInt32?
    private var delayWrapOffset: UInt64 = 0
    private var firstUnwrappedTimestamp: UInt64?
    private var firstDelayArrival: TimeInterval?
    private var shortDelay = 0.0
    private var longDelay = 0.0
    private var oneWayReceiveDelay = 0.0

    private let timestampRate: Double

    init(timestampRate: UInt32 = Self.defaultHighPerformanceTimestampRate) {
        precondition(timestampRate > 0)
        self.timestampRate = Double(timestampRate)
    }

    mutating func observe(_ observation: AppleVideoPacketObservation) {
        observe(observation, bandwidthProbeActivity: .active)
    }

    mutating func observe(
        _ observation: AppleVideoPacketObservation,
        bandwidthProbeActivity: AppleVideoBandwidthProbeActivity
    ) {
        didReceiveVideo = true
        totalPacketsReceived &+= 1
        updateTimestampStatistics(observation)
        switch bandwidthProbeActivity {
        case .active:
            updateBandwidthEstimate(observation)
        case .boundary, .suppressed:
            // Native continues feeding type-4 statistics while probe
            // detection is cooling down, with isProbing cleared. The first
            // such packet therefore closes the preceding probe window.
            finalizeBandwidthProbe()
        }
    }

    func feedback(at time: TimeInterval) -> AppleVideoRateControlInfo? {
        guard didReceiveVideo else { return nil }
        return AppleVideoRateControlInfo(
            rtpTimestamp: lastAcceptedTimestamp,
            estimatedBandwidthKilobitsPerSecond: serializedBandwidth,
            burstyLoss: 0,
            receivedPacketCount: lastAcceptedPacketCount,
            feedbackDelayMilliseconds: feedbackDelay(at: time),
            echoTimestamp: AppleVideoRateControlInfo.echoTimestamp(at: time),
            oneWayReceiveDelay: oneWayReceiveDelay
        )
    }

    var diagnostics: AppleVideoRateControlDiagnostics {
        AppleVideoRateControlDiagnostics(
            candidateBandwidthMegabitsPerSecond: lastCandidateBandwidth / 1_000_000,
            probeDurationMilliseconds: lastProbeDuration * 1_000,
            probeBytesAfterReference: lastProbeBytesAfterReference,
            timestampDelta: lastTimestampDelta,
            estimateState: estimateState.rawValue,
            pendingSampleCount: pendingCount
        )
    }

    private var serializedBandwidth: UInt32 {
        guard let estimatedBandwidth else { return 0 }
        let kilobits = UInt32(max(0, estimatedBandwidth / 1_000)) & ~UInt32(7)
        return estimateState == .stable ? kilobits &+ 1 : kilobits
    }

    private func feedbackDelay(at time: TimeInterval) -> UInt32 {
        guard let lastAcceptedArrival else { return UInt32.max }
        let milliseconds = max(0, (time - lastAcceptedArrival) * 1_000)
        guard milliseconds.isFinite, milliseconds < Double(UInt32.max) else {
            return UInt32.max
        }
        return UInt32(milliseconds.rounded(.towardZero))
    }

    private mutating func updateTimestampStatistics(_ observation: AppleVideoPacketObservation) {
        guard let previousTimestamp else {
            self.previousTimestamp = observation.rtpTimestamp
            return
        }
        guard observation.rtpTimestamp != previousTimestamp else { return }
        let delta = observation.rtpTimestamp &- previousTimestamp
        guard delta < 0x7fff_ffff else { return }

        self.previousTimestamp = observation.rtpTimestamp
        lastTimestampDelta = delta
        lastAcceptedTimestamp = observation.rtpTimestamp
        lastAcceptedPacketCount = totalPacketsReceived
        lastAcceptedArrival = observation.arrivalTime
        updateOneWayReceiveDelay(
            timestamp: observation.rtpTimestamp,
            arrivalTime: observation.arrivalTime
        )
    }

    private mutating func updateBandwidthEstimate(_ observation: AppleVideoPacketObservation) {
        guard var group = probeGroup else {
            probeGroup = ProbeGroup(
                timestamp: observation.rtpTimestamp,
                referenceArrival: observation.arrivalTime,
                lastArrival: observation.arrivalTime
            )
            return
        }
        guard observation.rtpTimestamp == group.timestamp else {
            finalize(group)
            probeGroup = ProbeGroup(
                timestamp: observation.rtpTimestamp,
                referenceArrival: observation.arrivalTime,
                lastArrival: observation.arrivalTime
            )
            return
        }

        group.bytesAfterReference &+= UInt64(max(0, observation.packetSize))
        group.packetsAfterReference += 1
        group.lastArrival = max(group.lastArrival, observation.arrivalTime)
        probeGroup = group
    }

    private mutating func finalizeBandwidthProbe() {
        guard let probeGroup else { return }
        finalize(probeGroup)
        self.probeGroup = nil
    }

    private mutating func finalize(_ group: ProbeGroup) {
        guard group.bytesAfterReference > Self.minimumProbeBytes,
              group.packetsAfterReference >= 1 else { return }
        let duration = group.lastArrival - group.referenceArrival
        guard duration > 0 else { return }
        let candidate = min(
            Self.maximumBandwidth,
            Double(group.bytesAfterReference) * 8 / duration
        )
        lastCandidateBandwidth = candidate
        lastProbeDuration = duration
        lastProbeBytesAfterReference = group.bytesAfterReference
        if duration < Self.minimumProbeDuration {
            consecutiveShortProbeCount += 1
            guard consecutiveShortProbeCount >= Self.shortProbeConfirmationCount else {
                // A skipped short window does not invalidate an already
                // established sudden-change direction in the native
                // estimator; it only withholds this candidate.
                estimateState = .insufficientProbeWindow
                return
            }
        } else {
            consecutiveShortProbeCount = 0
        }
        apply(candidate: candidate)
    }

    private mutating func apply(candidate: Double) {
        guard let estimatedBandwidth else {
            self.estimatedBandwidth = max(candidate, 100_000)
            estimateState = .initial
            return
        }
        let difference = candidate - estimatedBandwidth
        let isDown = candidate <= (1 - Self.suddenChangePercentage) * estimatedBandwidth
            || -difference > Self.suddenChangeMargin
        let isUp = candidate >= (1 + Self.suddenChangePercentage) * estimatedBandwidth
            || difference > Self.suddenChangeMargin
        guard isDown || isUp else {
            self.estimatedBandwidth = 0.1 * candidate + 0.9 * estimatedBandwidth
            clearPendingEstimate(state: .stable)
            return
        }

        let direction = isUp ? 1 : -1
        if direction != pendingDirection {
            pendingDirection = direction
            pendingBandwidth = candidate
            pendingCount = 1
        } else {
            pendingBandwidth += candidate
            pendingCount += 1
        }
        estimateState = direction > 0 ? .pendingUp : .pendingDown
        guard pendingCount >= Self.suddenChangeSamples else { return }

        self.estimatedBandwidth = pendingBandwidth / Double(pendingCount)
        clearPendingEstimate(state: .committed)
    }

    private mutating func clearPendingEstimate(state: EstimateState) {
        pendingDirection = 0
        pendingBandwidth = 0
        pendingCount = 0
        estimateState = state
    }

    private mutating func updateOneWayReceiveDelay(
        timestamp: UInt32,
        arrivalTime: TimeInterval
    ) {
        if let previous = delayPreviousTimestamp,
           timestamp < previous,
           previous &- timestamp > 0x7fff_ffff {
            delayWrapOffset &+= UInt64(UInt32.max) &+ 1
        }
        delayPreviousTimestamp = timestamp
        let unwrappedTimestamp = delayWrapOffset &+ UInt64(timestamp)
        guard let firstUnwrappedTimestamp, let firstDelayArrival else {
            self.firstUnwrappedTimestamp = unwrappedTimestamp
            self.firstDelayArrival = arrivalTime
            return
        }

        let sendRelative = Double(unwrappedTimestamp &- firstUnwrappedTimestamp) / timestampRate
        let receiveRelative = arrivalTime - firstDelayArrival
        let lag = receiveRelative - sendRelative
        shortDelay = 0.1 * lag + 0.9 * shortDelay
        longDelay = 0.0001 * lag + 0.9999 * longDelay
        let delay = shortDelay - longDelay
        if delay < 0 {
            longDelay = shortDelay
            oneWayReceiveDelay = 0
        } else {
            oneWayReceiveDelay = delay
        }
    }

}
