import Foundation

struct AppleVideoDisplayScheduler {
    struct DisplayUpdate {
        let frames: AppleVideoFrameStore.FrameBatch
        let requiresPresentation: Bool
        let targetTimestamp: TimeInterval
    }

    private let queueCapacity: Int
    private var queues = [Int: [AppleVideoFrameStore.Frame]]()
    private var lastEnqueuedSequence = [Int: UInt64]()
    private var lastDisplayedPresentationTime = [Int: TimeInterval]()
    private var latestDisplayTargetTimestamp: TimeInterval?
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
        _ frames: AppleVideoFrameStore.FrameBatch
    ) -> DisplayUpdate? {
        for (tileIndex, frame) in frames {
            guard frame.presentationTime
                    > lastDisplayedPresentationTime[tileIndex, default: -.infinity] else { continue }
            guard frame.sequence > lastEnqueuedSequence[tileIndex, default: 0] else { continue }
            lastEnqueuedSequence[tileIndex] = frame.sequence
            guard queues[tileIndex, default: []].count < queueCapacity else { continue }
            queues[tileIndex, default: []].append(frame)
            queues[tileIndex]?.sort {
                if $0.presentationTime != $1.presentationTime {
                    return $0.presentationTime < $1.presentationTime
                }
                return $0.sequence < $1.sequence
            }
        }
        guard let latestDisplayTargetTimestamp else { return nil }
        return displayUpdate(through: latestDisplayTargetTimestamp)
    }

    mutating func markNeedsPresentation() {
        forcePresentation = true
    }

    mutating func displayLinkDidFire(
        targetTimestamp: TimeInterval
    ) -> DisplayUpdate {
        latestDisplayTargetTimestamp = targetTimestamp
        return displayUpdate(through: targetTimestamp)
    }

    private mutating func displayUpdate(
        through targetTimestamp: TimeInterval
    ) -> DisplayUpdate {
        let frames = dequeueFrames(through: targetTimestamp)
        let requiresPresentation = forcePresentation || !frames.isEmpty
        forcePresentation = false
        return DisplayUpdate(
            frames: frames,
            requiresPresentation: requiresPresentation,
            targetTimestamp: targetTimestamp
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
        forcePresentation = false
    }

    mutating func invalidateDisplayTarget() {
        latestDisplayTargetTimestamp = nil
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
