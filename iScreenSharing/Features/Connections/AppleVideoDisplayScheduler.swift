import Foundation

struct AppleVideoDisplayScheduler {
    private struct QueuedBatch {
        let frames: AppleVideoFrameStore.FrameBatch
        let presentationTime: TimeInterval
    }

    enum Trigger: Equatable {
        case enqueueUsingPreviousTarget
        case displayLinkTick
    }

    struct DisplayUpdate {
        let frames: AppleVideoFrameStore.FrameBatch
        let requiresPresentation: Bool
        let targetTimestamp: TimeInterval?
        let displayPeriod: TimeInterval?
        let trigger: Trigger
    }

    private let queueCapacity: Int
    private let presentsOnEnqueue: Bool
    private let preservesEnqueuedBatches: Bool
    private let presentsEarlyWhenBacklogged: Bool
    private let coalescesDueBatches: Bool
    private var queues = [Int: [AppleVideoFrameStore.Frame]]()
    private var batches = [QueuedBatch]()
    private var lastEnqueuedSequence = [Int: UInt64]()
    private var lastDisplayedPresentationTime = [Int: TimeInterval]()
    private var latestDisplayTargetTimestamp: TimeInterval?
    private var latestDisplayPeriod: TimeInterval?
    private var forcePresentation = false

    init(
        queueCapacity: Int = 16,
        presentsOnEnqueue: Bool = true,
        preservesEnqueuedBatches: Bool = false,
        presentsEarlyWhenBacklogged: Bool = false,
        coalescesDueBatches: Bool = false
    ) {
        precondition(queueCapacity > 0)
        self.queueCapacity = queueCapacity
        self.presentsOnEnqueue = presentsOnEnqueue
        self.preservesEnqueuedBatches = preservesEnqueuedBatches
        self.presentsEarlyWhenBacklogged = presentsEarlyWhenBacklogged
        self.coalescesDueBatches = coalescesDueBatches
    }

    var queuedFrameCount: Int {
        if preservesEnqueuedBatches {
            return batches.reduce(0) { $0 + $1.frames.count }
        }
        return queues.values.reduce(0) { $0 + $1.count }
    }

    @discardableResult
    mutating func enqueue(
        _ frames: AppleVideoFrameStore.FrameBatch,
        presentsImmediately: Bool? = nil
    ) -> DisplayUpdate? {
        if preservesEnqueuedBatches {
            enqueueBatch(frames)
            return nil
        }
        let shouldPresentOnEnqueue = presentsImmediately ?? presentsOnEnqueue
        for (tileIndex, frame) in frames {
            guard frame.presentationTime
                    > lastDisplayedPresentationTime[tileIndex, default: -.infinity] else { continue }
            guard frame.sequence > lastEnqueuedSequence[tileIndex, default: 0] else { continue }
            lastEnqueuedSequence[tileIndex] = frame.sequence
            if !shouldPresentOnEnqueue {
                queues[tileIndex] = [frame]
                continue
            }
            guard queues[tileIndex, default: []].count < queueCapacity else { continue }
            queues[tileIndex, default: []].append(frame)
            queues[tileIndex]?.sort {
                if $0.presentationTime != $1.presentationTime {
                    return $0.presentationTime < $1.presentationTime
                }
                return $0.sequence < $1.sequence
            }
        }
        guard shouldPresentOnEnqueue, let latestDisplayTargetTimestamp else { return nil }
        return displayUpdate(
            through: latestDisplayTargetTimestamp,
            trigger: .enqueueUsingPreviousTarget
        )
    }

    mutating func markNeedsPresentation() {
        forcePresentation = true
    }

    mutating func displayLinkDidFire(
        targetTimestamp: TimeInterval,
        period: TimeInterval = 0
    ) -> DisplayUpdate {
        latestDisplayTargetTimestamp = targetTimestamp
        latestDisplayPeriod = period > 0 ? period : nil
        return displayUpdate(through: targetTimestamp, trigger: .displayLinkTick)
    }

    private mutating func displayUpdate(
        through targetTimestamp: TimeInterval,
        trigger: Trigger
    ) -> DisplayUpdate {
        let frames = dequeueFrames(through: targetTimestamp)
        let requiresPresentation = forcePresentation || !frames.isEmpty
        forcePresentation = false
        return DisplayUpdate(
            frames: frames,
            requiresPresentation: requiresPresentation,
            targetTimestamp: targetTimestamp,
            displayPeriod: latestDisplayPeriod,
            trigger: trigger
        )
    }

    mutating func presentationDidFail() {
        forcePresentation = true
    }

    mutating func takeLatestFrames() -> AppleVideoFrameStore.FrameBatch {
        if preservesEnqueuedBatches {
            let frames = batches.last?.frames ?? [:]
            markDisplayed(frames)
            batches.removeAll(keepingCapacity: true)
            return frames
        }
        let frames = queues.compactMapValues(\.last)
        markDisplayed(frames)
        queues.removeAll(keepingCapacity: true)
        return frames
    }

    mutating func reset() {
        queues.removeAll(keepingCapacity: false)
        batches.removeAll(keepingCapacity: false)
        lastEnqueuedSequence.removeAll(keepingCapacity: false)
        lastDisplayedPresentationTime.removeAll(keepingCapacity: false)
        latestDisplayTargetTimestamp = nil
        latestDisplayPeriod = nil
        forcePresentation = false
    }

    mutating func invalidateDisplayTarget() {
        latestDisplayTargetTimestamp = nil
        latestDisplayPeriod = nil
    }

    private mutating func dequeueFrames(
        through targetTimestamp: TimeInterval
    ) -> AppleVideoFrameStore.FrameBatch {
        if preservesEnqueuedBatches {
            guard let batch = batches.first else { return [:] }
            if coalescesDueBatches {
                let dueCount = batches.prefix { $0.presentationTime <= targetTimestamp }.count
                if dueCount > 0 {
                    // Batches are complete canvas snapshots. Catch up by selecting
                    // one snapshot, never by mixing tiles from different batches.
                    let frames = batches[dueCount - 1].frames
                    batches.removeFirst(dueCount)
                    markDisplayed(frames)
                    return frames
                }
            }
            let isEligible = batch.presentationTime <= targetTimestamp
            guard isEligible || presentsEarlyWhenBacklogged && batches.count > 1 else {
                return [:]
            }
            batches.removeFirst()
            markDisplayed(batch.frames)
            return batch.frames
        }
        var result = AppleVideoFrameStore.FrameBatch()
        for tileIndex in Array(queues.keys) {
            guard let queue = queues[tileIndex], !queue.isEmpty else { continue }
            let eligibleCount = queue.prefix {
                $0.presentationTime <= targetTimestamp
            }.count
            guard eligibleCount > 0 else { continue }
            result[tileIndex] = queue[eligibleCount - 1]
            lastDisplayedPresentationTime[tileIndex] = queue[eligibleCount - 1].presentationTime
            queues[tileIndex]?.removeFirst(eligibleCount)
            if queues[tileIndex]?.isEmpty == true { queues.removeValue(forKey: tileIndex) }
        }
        return result
    }

    private mutating func enqueueBatch(_ frames: AppleVideoFrameStore.FrameBatch) {
        let newFrames = frames.filter { tileIndex, frame in
            frame.presentationTime
                > lastDisplayedPresentationTime[tileIndex, default: -.infinity]
                && frame.sequence > lastEnqueuedSequence[tileIndex, default: 0]
        }
        guard let presentationTime = newFrames.values.map(\.presentationTime).max() else {
            return
        }
        for (tileIndex, frame) in newFrames {
            lastEnqueuedSequence[tileIndex] = frame.sequence
        }
        if batches.count == queueCapacity {
            batches.removeFirst()
        }
        batches.append(QueuedBatch(frames: frames, presentationTime: presentationTime))
    }

    private mutating func markDisplayed(_ frames: AppleVideoFrameStore.FrameBatch) {
        for (tileIndex, frame) in frames {
            lastDisplayedPresentationTime[tileIndex] = max(
                lastDisplayedPresentationTime[tileIndex, default: -.infinity],
                frame.presentationTime
            )
        }
    }
}
