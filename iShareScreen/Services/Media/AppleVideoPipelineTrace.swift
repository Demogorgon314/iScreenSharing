import Foundation

struct AppleVideoDistributionSnapshot: Equatable, Sendable {
    var minimum = 0.0
    var p50 = 0.0
    var p95 = 0.0
    var maximum = 0.0

    static let zero = AppleVideoDistributionSnapshot()
}

struct AppleVideoPipelineLatencySnapshot: Equatable, Sendable {
    var datagramSpanMilliseconds = AppleVideoDistributionSnapshot.zero
    var completingDatagramToAssemblyMilliseconds = AppleVideoDistributionSnapshot.zero
    var assemblyToDecodeEntryMilliseconds = AppleVideoDistributionSnapshot.zero
    var decodeEntryToSubmitMilliseconds = AppleVideoDistributionSnapshot.zero
    var decoderSubmitToCallbackMilliseconds = AppleVideoDistributionSnapshot.zero
    var decoderCallbackToPlaybackMilliseconds = AppleVideoDistributionSnapshot.zero
    var playbackToMainMilliseconds = AppleVideoDistributionSnapshot.zero
    var mainToSchedulerMilliseconds = AppleVideoDistributionSnapshot.zero
    var schedulerToDrawableMilliseconds = AppleVideoDistributionSnapshot.zero
    var drawableWaitMilliseconds = AppleVideoDistributionSnapshot.zero
    var encodeMilliseconds = AppleVideoDistributionSnapshot.zero
    var encodeEndToCommitMilliseconds = AppleVideoDistributionSnapshot.zero
    var commitToScheduledCallbackMilliseconds = AppleVideoDistributionSnapshot.zero
    var gpuQueueWaitMilliseconds = AppleVideoDistributionSnapshot.zero
    var gpuExecutionMilliseconds = AppleVideoDistributionSnapshot.zero
    var gpuEndToDisplayMilliseconds = AppleVideoDistributionSnapshot.zero
    var commitToDisplayMilliseconds = AppleVideoDistributionSnapshot.zero
    var firstDatagramToDisplayMilliseconds = AppleVideoDistributionSnapshot.zero
    var decodeEntryToDisplayMilliseconds = AppleVideoDistributionSnapshot.zero
    var decoderSubmitToDisplayMilliseconds = AppleVideoDistributionSnapshot.zero
    var decoderCallbackToDisplayMilliseconds = AppleVideoDistributionSnapshot.zero
    var schedulerToTargetMilliseconds = AppleVideoDistributionSnapshot.zero
    var presentationToTargetMilliseconds = AppleVideoDistributionSnapshot.zero
    var commitLeadToTargetMilliseconds = AppleVideoDistributionSnapshot.zero
    var gpuEndLeadToTargetMilliseconds = AppleVideoDistributionSnapshot.zero
    var targetToDisplayMilliseconds = AppleVideoDistributionSnapshot.zero
    var targetPhasePeriods = AppleVideoDistributionSnapshot.zero
    var immediatePreviousTargetAgeMilliseconds = AppleVideoDistributionSnapshot.zero
    var displayLinkMissCount = 0
    var displayLinkBatchCount = 0
    var immediateBatchCount = 0
    var finalizedBatchCount = 0
    var traceEvictionCount = 0

    static let zero = AppleVideoPipelineLatencySnapshot()
}

struct AppleVideoPipelineTrace {
    private static let maximumFrameCount = 512
    private static let maximumBatchCount = 64
    private static let traceLifetime: TimeInterval = 2

    private struct FrameTiming {
        let accessUnitTiming: AppleHEVCAccessUnit.Timing?
        let decodeEnteredAt: TimeInterval
        let decoderSubmittedAt: TimeInterval
        let decoderOutputAt: TimeInterval
        let playbackHandledAt: TimeInterval
        let mainDeliveredAt: TimeInterval
        let presentationTime: TimeInterval
        var schedulerSelectedAt: TimeInterval?
    }

    private struct BatchTiming {
        let frameKeys: [UInt64]
        let createdAt: TimeInterval
        let drawableWaitStartedAt: TimeInterval
        let drawableAcquiredAt: TimeInterval
        let encodeStartedAt: TimeInterval
        let encodeEndedAt: TimeInterval
        let targetTimestamp: TimeInterval?
        let displayPeriod: TimeInterval?
        let isDisplayLinkTriggered: Bool
        var commitAt: TimeInterval?
        var scheduledAt: TimeInterval?
        var gpuStartAt: TimeInterval?
        var gpuEndAt: TimeInterval?
        var completionObserved = false
        var presentedAt: TimeInterval?
    }

    private struct Accumulator {
        var datagramSpan = [TimeInterval]()
        var completingDatagramToAssembly = [TimeInterval]()
        var assemblyToDecodeEntry = [TimeInterval]()
        var decodeEntryToSubmit = [TimeInterval]()
        var decoderSubmitToCallback = [TimeInterval]()
        var decoderCallbackToPlayback = [TimeInterval]()
        var playbackToMain = [TimeInterval]()
        var mainToScheduler = [TimeInterval]()
        var schedulerToDrawable = [TimeInterval]()
        var drawableWait = [TimeInterval]()
        var encode = [TimeInterval]()
        var encodeEndToCommit = [TimeInterval]()
        var commitToScheduledCallback = [TimeInterval]()
        var gpuQueueWait = [TimeInterval]()
        var gpuExecution = [TimeInterval]()
        var gpuEndToDisplay = [TimeInterval]()
        var commitToDisplay = [TimeInterval]()
        var firstDatagramToDisplay = [TimeInterval]()
        var decodeEntryToDisplay = [TimeInterval]()
        var decoderSubmitToDisplay = [TimeInterval]()
        var decoderCallbackToDisplay = [TimeInterval]()
        var schedulerToTarget = [TimeInterval]()
        var presentationToTarget = [TimeInterval]()
        var commitLeadToTarget = [TimeInterval]()
        var gpuEndLeadToTarget = [TimeInterval]()
        var targetToDisplay = [TimeInterval]()
        var targetPhasePeriods = [Double]()
        var immediatePreviousTargetAge = [TimeInterval]()
        var displayLinkMissCount = 0
        var displayLinkBatchCount = 0
        var immediateBatchCount = 0
        var finalizedBatchCount = 0
        var traceEvictionCount = 0
    }

    private var frames = [UInt64: FrameTiming]()
    private var batches = [UInt64: BatchTiming]()
    private var nextBatchID: UInt64 = 0
    private var accumulator = Accumulator()

    mutating func recordFrameDelivery(
        frameKey: UInt64,
        accessUnitTiming: AppleHEVCAccessUnit.Timing?,
        decodeEnteredAt: TimeInterval,
        decoderSubmittedAt: TimeInterval,
        decoderOutputAt: TimeInterval,
        playbackHandledAt: TimeInterval,
        mainDeliveredAt: TimeInterval,
        presentationTime: TimeInterval
    ) {
        guard frames[frameKey] == nil else { return }
        evictStaleTraces(at: mainDeliveredAt)
        if frames.count >= Self.maximumFrameCount {
            let activeFrameKeys = Set(batches.values.flatMap(\.frameKeys))
            if let oldestInactive = frames
                .filter({ !activeFrameKeys.contains($0.key) })
                .min(by: { $0.value.decoderOutputAt < $1.value.decoderOutputAt })?.key {
                frames.removeValue(forKey: oldestInactive)
                accumulator.traceEvictionCount += 1
            } else {
                accumulator.traceEvictionCount += 1
                return
            }
        }
        frames[frameKey] = FrameTiming(
            accessUnitTiming: accessUnitTiming,
            decodeEnteredAt: decodeEnteredAt,
            decoderSubmittedAt: decoderSubmittedAt,
            decoderOutputAt: decoderOutputAt,
            playbackHandledAt: playbackHandledAt,
            mainDeliveredAt: mainDeliveredAt,
            presentationTime: presentationTime
        )
    }

    mutating func recordSchedulerSelection(
        frameKeys: [UInt64],
        selectedAt: TimeInterval
    ) {
        for frameKey in frameKeys {
            guard var frame = frames[frameKey] else { continue }
            frame.schedulerSelectedAt = selectedAt
            frames[frameKey] = frame
        }
    }

    mutating func beginRenderBatch(
        frameKeys: [UInt64],
        drawableWaitStartedAt: TimeInterval,
        drawableAcquiredAt: TimeInterval,
        encodeStartedAt: TimeInterval,
        encodeEndedAt: TimeInterval,
        targetTimestamp: TimeInterval?,
        displayPeriod: TimeInterval?,
        isDisplayLinkTriggered: Bool
    ) -> UInt64? {
        let uniqueFrameKeys = Array(Set(frameKeys)).sorted()
        guard !uniqueFrameKeys.isEmpty else { return nil }
        evictStaleTraces(at: encodeEndedAt)
        if batches.count >= Self.maximumBatchCount,
           let oldest = batches.min(by: { $0.value.createdAt < $1.value.createdAt })?.key {
            evictBatch(oldest)
        }
        nextBatchID &+= 1
        let batchID = nextBatchID
        batches[batchID] = BatchTiming(
            frameKeys: uniqueFrameKeys,
            createdAt: drawableWaitStartedAt,
            drawableWaitStartedAt: drawableWaitStartedAt,
            drawableAcquiredAt: drawableAcquiredAt,
            encodeStartedAt: encodeStartedAt,
            encodeEndedAt: encodeEndedAt,
            targetTimestamp: targetTimestamp,
            displayPeriod: displayPeriod,
            isDisplayLinkTriggered: isDisplayLinkTriggered
        )
        return batchID
    }

    mutating func recordCommitted(batchID: UInt64, at time: TimeInterval) {
        updateBatch(batchID) { $0.commitAt = time }
        finalizeIfReady(batchID)
    }

    mutating func recordScheduled(batchID: UInt64, at time: TimeInterval) {
        updateBatch(batchID) { $0.scheduledAt = time }
        finalizeIfReady(batchID)
    }

    mutating func recordCompleted(
        batchID: UInt64,
        gpuStart: TimeInterval?,
        gpuEnd: TimeInterval?
    ) {
        updateBatch(batchID) {
            $0.completionObserved = true
            $0.gpuStartAt = gpuStart
            $0.gpuEndAt = gpuEnd
        }
        finalizeIfReady(batchID)
    }

    mutating func recordPresented(batchID: UInt64, at time: TimeInterval) {
        updateBatch(batchID) { $0.presentedAt = time }
        finalizeIfReady(batchID)
    }

    mutating func sample(at time: TimeInterval) -> AppleVideoPipelineLatencySnapshot {
        for batchID in Array(batches.keys) {
            finalizeIfReady(batchID, allowsMissingScheduledCallback: true)
        }
        evictStaleTraces(at: time)
        let snapshot = AppleVideoPipelineLatencySnapshot(
            datagramSpanMilliseconds: Self.milliseconds(accumulator.datagramSpan),
            completingDatagramToAssemblyMilliseconds: Self.milliseconds(
                accumulator.completingDatagramToAssembly
            ),
            assemblyToDecodeEntryMilliseconds: Self.milliseconds(
                accumulator.assemblyToDecodeEntry
            ),
            decodeEntryToSubmitMilliseconds: Self.milliseconds(
                accumulator.decodeEntryToSubmit
            ),
            decoderSubmitToCallbackMilliseconds: Self.milliseconds(
                accumulator.decoderSubmitToCallback
            ),
            decoderCallbackToPlaybackMilliseconds: Self.milliseconds(
                accumulator.decoderCallbackToPlayback
            ),
            playbackToMainMilliseconds: Self.milliseconds(accumulator.playbackToMain),
            mainToSchedulerMilliseconds: Self.milliseconds(accumulator.mainToScheduler),
            schedulerToDrawableMilliseconds: Self.milliseconds(accumulator.schedulerToDrawable),
            drawableWaitMilliseconds: Self.milliseconds(accumulator.drawableWait),
            encodeMilliseconds: Self.milliseconds(accumulator.encode),
            encodeEndToCommitMilliseconds: Self.milliseconds(accumulator.encodeEndToCommit),
            commitToScheduledCallbackMilliseconds: Self.milliseconds(
                accumulator.commitToScheduledCallback
            ),
            gpuQueueWaitMilliseconds: Self.milliseconds(accumulator.gpuQueueWait),
            gpuExecutionMilliseconds: Self.milliseconds(accumulator.gpuExecution),
            gpuEndToDisplayMilliseconds: Self.milliseconds(accumulator.gpuEndToDisplay),
            commitToDisplayMilliseconds: Self.milliseconds(accumulator.commitToDisplay),
            firstDatagramToDisplayMilliseconds: Self.milliseconds(
                accumulator.firstDatagramToDisplay
            ),
            decodeEntryToDisplayMilliseconds: Self.milliseconds(
                accumulator.decodeEntryToDisplay
            ),
            decoderSubmitToDisplayMilliseconds: Self.milliseconds(
                accumulator.decoderSubmitToDisplay
            ),
            decoderCallbackToDisplayMilliseconds: Self.milliseconds(
                accumulator.decoderCallbackToDisplay
            ),
            schedulerToTargetMilliseconds: Self.milliseconds(accumulator.schedulerToTarget),
            presentationToTargetMilliseconds: Self.milliseconds(
                accumulator.presentationToTarget
            ),
            commitLeadToTargetMilliseconds: Self.milliseconds(accumulator.commitLeadToTarget),
            gpuEndLeadToTargetMilliseconds: Self.milliseconds(accumulator.gpuEndLeadToTarget),
            targetToDisplayMilliseconds: Self.milliseconds(accumulator.targetToDisplay),
            targetPhasePeriods: Self.distribution(accumulator.targetPhasePeriods),
            immediatePreviousTargetAgeMilliseconds: Self.milliseconds(
                accumulator.immediatePreviousTargetAge
            ),
            displayLinkMissCount: accumulator.displayLinkMissCount,
            displayLinkBatchCount: accumulator.displayLinkBatchCount,
            immediateBatchCount: accumulator.immediateBatchCount,
            finalizedBatchCount: accumulator.finalizedBatchCount,
            traceEvictionCount: accumulator.traceEvictionCount
        )
        accumulator = Accumulator()
        return snapshot
    }

    mutating func reset() {
        frames.removeAll(keepingCapacity: false)
        batches.removeAll(keepingCapacity: false)
        accumulator = Accumulator()
    }

    private mutating func updateBatch(
        _ batchID: UInt64,
        update: (inout BatchTiming) -> Void
    ) {
        guard var batch = batches[batchID] else { return }
        update(&batch)
        batches[batchID] = batch
    }

    private mutating func finalizeIfReady(
        _ batchID: UInt64,
        allowsMissingScheduledCallback: Bool = false
    ) {
        guard let batch = batches[batchID],
              let commitAt = batch.commitAt,
              batch.completionObserved,
              allowsMissingScheduledCallback || batch.scheduledAt != nil,
              let presentedAt = batch.presentedAt else { return }

        let frameTimings = batch.frameKeys.compactMap { frames[$0] }
        for frame in frameTimings {
            if let timing = frame.accessUnitTiming {
                Self.appendNonnegative(
                    timing.completingDatagramObservedAt - timing.firstDatagramObservedAt,
                    to: &accumulator.datagramSpan
                )
                Self.appendNonnegative(
                    timing.assemblyCompletedAt - timing.completingDatagramObservedAt,
                    to: &accumulator.completingDatagramToAssembly
                )
                Self.appendNonnegative(
                    frame.decodeEnteredAt - timing.assemblyCompletedAt,
                    to: &accumulator.assemblyToDecodeEntry
                )
                Self.appendNonnegative(
                    presentedAt - timing.firstDatagramObservedAt,
                    to: &accumulator.firstDatagramToDisplay
                )
            }
            Self.appendNonnegative(
                frame.decoderSubmittedAt - frame.decodeEnteredAt,
                to: &accumulator.decodeEntryToSubmit
            )
            Self.appendNonnegative(
                frame.decoderOutputAt - frame.decoderSubmittedAt,
                to: &accumulator.decoderSubmitToCallback
            )
            Self.appendNonnegative(
                frame.playbackHandledAt - frame.decoderOutputAt,
                to: &accumulator.decoderCallbackToPlayback
            )
            Self.appendNonnegative(
                frame.mainDeliveredAt - frame.playbackHandledAt,
                to: &accumulator.playbackToMain
            )
            if let schedulerSelectedAt = frame.schedulerSelectedAt {
                Self.appendNonnegative(
                    schedulerSelectedAt - frame.mainDeliveredAt,
                    to: &accumulator.mainToScheduler
                )
                Self.appendNonnegative(
                    batch.drawableWaitStartedAt - schedulerSelectedAt,
                    to: &accumulator.schedulerToDrawable
                )
            }
            Self.appendNonnegative(
                presentedAt - frame.decodeEnteredAt,
                to: &accumulator.decodeEntryToDisplay
            )
            Self.appendNonnegative(
                presentedAt - frame.decoderSubmittedAt,
                to: &accumulator.decoderSubmitToDisplay
            )
            Self.appendNonnegative(
                presentedAt - frame.decoderOutputAt,
                to: &accumulator.decoderCallbackToDisplay
            )
        }
        Self.appendNonnegative(
            batch.drawableAcquiredAt - batch.drawableWaitStartedAt,
            to: &accumulator.drawableWait
        )
        Self.appendNonnegative(
            batch.encodeEndedAt - batch.encodeStartedAt,
            to: &accumulator.encode
        )
        Self.appendNonnegative(commitAt - batch.encodeEndedAt, to: &accumulator.encodeEndToCommit)
        if let scheduledAt = batch.scheduledAt {
            Self.appendNonnegative(
                scheduledAt - commitAt,
                to: &accumulator.commitToScheduledCallback
            )
        }
        if let gpuStartAt = batch.gpuStartAt {
            Self.appendNonnegative(gpuStartAt - commitAt, to: &accumulator.gpuQueueWait)
        }
        if let gpuStartAt = batch.gpuStartAt, let gpuEndAt = batch.gpuEndAt {
            Self.appendNonnegative(gpuEndAt - gpuStartAt, to: &accumulator.gpuExecution)
        }
        if let gpuEndAt = batch.gpuEndAt {
            Self.appendNonnegative(presentedAt - gpuEndAt, to: &accumulator.gpuEndToDisplay)
        }
        Self.appendNonnegative(presentedAt - commitAt, to: &accumulator.commitToDisplay)
        if batch.isDisplayLinkTriggered {
            accumulator.displayLinkBatchCount += 1
        } else {
            accumulator.immediateBatchCount += 1
        }
        if batch.isDisplayLinkTriggered, let targetTimestamp = batch.targetTimestamp {
            let targetDelta = presentedAt - targetTimestamp
            Self.appendFinite(targetDelta, to: &accumulator.targetToDisplay)
            Self.appendFinite(targetTimestamp - commitAt, to: &accumulator.commitLeadToTarget)
            if let gpuEndAt = batch.gpuEndAt {
                Self.appendFinite(
                    targetTimestamp - gpuEndAt,
                    to: &accumulator.gpuEndLeadToTarget
                )
            }
            for frame in frameTimings {
                if let schedulerSelectedAt = frame.schedulerSelectedAt {
                    Self.appendFinite(
                        targetTimestamp - schedulerSelectedAt,
                        to: &accumulator.schedulerToTarget
                    )
                }
                Self.appendFinite(
                    targetTimestamp - frame.presentationTime,
                    to: &accumulator.presentationToTarget
                )
            }
            if let displayPeriod = batch.displayPeriod, displayPeriod > 0 {
                let targetPhasePeriods = targetDelta / displayPeriod
                accumulator.targetPhasePeriods.append(targetPhasePeriods)
                if targetPhasePeriods >= 1 - Double.ulpOfOne.squareRoot() {
                    accumulator.displayLinkMissCount += 1
                }
            }
        } else if let targetTimestamp = batch.targetTimestamp {
            Self.appendNonnegative(
                batch.drawableWaitStartedAt - targetTimestamp,
                to: &accumulator.immediatePreviousTargetAge
            )
        }
        accumulator.finalizedBatchCount += 1
        batches.removeValue(forKey: batchID)
        let activeFrameKeys = Set(batches.values.flatMap(\.frameKeys))
        for frameKey in batch.frameKeys where !activeFrameKeys.contains(frameKey) {
            frames.removeValue(forKey: frameKey)
        }
    }

    private mutating func evictStaleTraces(at time: TimeInterval) {
        let staleBatchIDs = batches.compactMap { batchID, batch in
            time - batch.createdAt > Self.traceLifetime ? batchID : nil
        }
        for batchID in staleBatchIDs { evictBatch(batchID) }
        let activeFrameKeys = Set(batches.values.flatMap(\.frameKeys))
        let staleFrameKeys: [UInt64] = frames.compactMap { frameKey, frame -> UInt64? in
            guard !activeFrameKeys.contains(frameKey),
                  time - frame.decoderOutputAt > Self.traceLifetime else { return nil }
            return frameKey
        }
        for frameKey in staleFrameKeys {
            frames.removeValue(forKey: frameKey)
            accumulator.traceEvictionCount += 1
        }
    }

    private mutating func evictBatch(_ batchID: UInt64) {
        guard let batch = batches.removeValue(forKey: batchID) else { return }
        accumulator.traceEvictionCount += 1
        let activeFrameKeys = Set(batches.values.flatMap(\.frameKeys))
        for frameKey in batch.frameKeys where !activeFrameKeys.contains(frameKey) {
            if frames.removeValue(forKey: frameKey) != nil {
                accumulator.traceEvictionCount += 1
            }
        }
    }

    private static func appendNonnegative(
        _ value: TimeInterval,
        to values: inout [TimeInterval]
    ) {
        guard value.isFinite, value >= 0 else { return }
        values.append(value)
    }

    private static func appendFinite(_ value: Double, to values: inout [Double]) {
        guard value.isFinite else { return }
        values.append(value)
    }

    private static func milliseconds(
        _ values: [TimeInterval]
    ) -> AppleVideoDistributionSnapshot {
        distribution(values.map { $0 * 1_000 })
    }

    private static func distribution(
        _ values: [Double]
    ) -> AppleVideoDistributionSnapshot {
        guard !values.isEmpty else { return .zero }
        let sorted = values.sorted()
        return AppleVideoDistributionSnapshot(
            minimum: sorted[0],
            p50: percentile(sorted, 0.50),
            p95: percentile(sorted, 0.95),
            maximum: sorted[sorted.count - 1]
        )
    }

    private static func percentile(_ sortedValues: [Double], _ percentile: Double) -> Double {
        let rank = max(
            0,
            min(
                sortedValues.count - 1,
                Int(ceil(percentile * Double(sortedValues.count))) - 1
            )
        )
        return sortedValues[rank]
    }
}
