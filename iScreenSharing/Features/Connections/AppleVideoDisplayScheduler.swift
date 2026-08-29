import Foundation

struct AppleVideoDisplayScheduler {
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
    private var queues = [Int: [AppleVideoFrameStore.Frame]]()
    private var lastEnqueuedSequence = [Int: UInt64]()
    private var lastDisplayedPresentationTime = [Int: TimeInterval]()
    private var latestDisplayTargetTimestamp: TimeInterval?
    private var latestDisplayPeriod: TimeInterval?
    private var forcePresentation = false

    init(queueCapacity: Int = 16) {
        precondition(queueCapacity > 0)
        self.queueCapacity = queueCapacity
    }

    var queuedFrameCount: Int {
        queues.values.reduce(0) { $0 + $1.count }
    }

    @discardableResult
    mutating func enqueue(
        _ frames: AppleVideoFrameStore.FrameBatch,
        presentsImmediately: Bool = true
    ) -> DisplayUpdate? {
        for (tileIndex, frame) in frames {
            guard frame.presentationTime
                    > lastDisplayedPresentationTime[tileIndex, default: -.infinity] else { continue }
            guard frame.sequence > lastEnqueuedSequence[tileIndex, default: 0] else { continue }
            lastEnqueuedSequence[tileIndex] = frame.sequence
            if !presentsImmediately {
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
        guard presentsImmediately, let latestDisplayTargetTimestamp else { return nil }
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
        let frames = queues.compactMapValues(\.last)
        for (tileIndex, frame) in frames {
            lastDisplayedPresentationTime[tileIndex] = frame.presentationTime
        }
        queues.removeAll(keepingCapacity: true)
        return frames
    }

    mutating func reset() {
        queues.removeAll(keepingCapacity: false)
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
}
