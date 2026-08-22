import CoreVideo
import Foundation

final class AppleVideoFrameStore: @unchecked Sendable {
    struct Frame: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let decodingOrderNumber: UInt16?
        let rtpTimestamp: UInt32?
        let decodedAt: TimeInterval
        let sequence: UInt64
    }

    private struct TimestampGroup {
        let timestamp: UInt32
        let generation: UInt64
        var frames = FrameBatch()
    }

    private struct SealedTimestamp {
        let expectedTileIndices: Set<Int>
        let sequence: UInt64
    }

    typealias FrameBatch = [Int: Frame]
    typealias Observer = @MainActor @Sendable (FrameBatch) -> Void

    private let expectedTileCount: Int?
    private let presentationDelay: TimeInterval
    private let lock = NSLock()
    private var frames = FrameBatch()
    private var pendingFrames = FrameBatch()
    private var timestampGroup: TimestampGroup?
    private var sealedTimestamps = [UInt32: SealedTimestamp]()
    private var nextSequence: UInt64 = 0
    private var nextTimestampGeneration: UInt64 = 0
    private var nextSealSequence: UInt64 = 0
    private var deliveryScheduled = false
    private var observers = [UUID: Observer]()

    init(
        expectedTileCount: Int? = nil,
        presentationDelay: TimeInterval = 1.0 / 60.0
    ) {
        self.expectedTileCount = expectedTileCount.flatMap { $0 > 0 ? $0 : nil }
        self.presentationDelay = max(0, presentationDelay)
    }

    @discardableResult
    func addObserver(_ observer: @escaping Observer) -> UUID {
        lock.withFrameStoreLock {
            let identifier = UUID()
            observers[identifier] = observer
            return identifier
        }
    }

    func removeObserver(_ identifier: UUID) {
        _ = lock.withFrameStoreLock {
            observers.removeValue(forKey: identifier)
        }
    }

    func frame(at tileIndex: Int) -> CVPixelBuffer? {
        lock.withFrameStoreLock { frames[tileIndex]?.pixelBuffer }
    }

    func storedFrame(at tileIndex: Int) -> Frame? {
        lock.withFrameStoreLock { frames[tileIndex] }
    }

    func removeAllFrames() {
        lock.withFrameStoreLock {
            frames.removeAll(keepingCapacity: false)
            pendingFrames.removeAll(keepingCapacity: false)
            timestampGroup = nil
            sealedTimestamps.removeAll(keepingCapacity: false)
            nextTimestampGeneration &+= 1
        }
    }

    func seal(rtpTimestamp: UInt32, expectedTileIndices: Set<Int>) {
        guard !expectedTileIndices.isEmpty else { return }
        let shouldSchedule = lock.withFrameStoreLock {
            nextSealSequence &+= 1
            sealedTimestamps[rtpTimestamp] = SealedTimestamp(
                expectedTileIndices: expectedTileIndices,
                sequence: nextSealSequence
            )
            discardStaleSealedTimestamps()
            guard let group = timestampGroup,
                  group.timestamp == rtpTimestamp,
                  isComplete(group) else { return false }
            finalize(group)
            timestampGroup = nil
            return scheduleDeliveryIfNeeded()
        }
        if shouldSchedule { scheduleDelivery() }
    }

    func publish(
        _ pixelBuffer: CVPixelBuffer,
        at tileIndex: Int,
        decodingOrderNumber: UInt16? = nil,
        rtpTimestamp: UInt32? = nil,
        decodedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        let scheduling = lock.withFrameStoreLock {
            nextSequence &+= 1
            let frame = Frame(
                pixelBuffer: pixelBuffer,
                decodingOrderNumber: decodingOrderNumber,
                rtpTimestamp: rtpTimestamp,
                decodedAt: decodedAt,
                sequence: nextSequence
            )
            guard let rtpTimestamp else {
                frames[tileIndex] = frame
                pendingFrames[tileIndex] = frame
                return (scheduleDeliveryIfNeeded(), nil as TimestampGroup?)
            }

            var shouldDeliver = false
            var deadlineGroup: TimestampGroup?
            if timestampGroup?.timestamp != rtpTimestamp {
                if let timestampGroup {
                    finalize(timestampGroup)
                    shouldDeliver = scheduleDeliveryIfNeeded()
                }
                nextTimestampGeneration &+= 1
                timestampGroup = TimestampGroup(
                    timestamp: rtpTimestamp,
                    generation: nextTimestampGeneration
                )
                deadlineGroup = timestampGroup
            }
            timestampGroup?.frames[tileIndex] = frame
            if let group = timestampGroup,
               isComplete(group) {
                finalize(group)
                timestampGroup = nil
                deadlineGroup = nil
                let newlyScheduled = scheduleDeliveryIfNeeded()
                shouldDeliver = shouldDeliver || newlyScheduled
            }
            return (shouldDeliver, deadlineGroup)
        }
        if scheduling.0 { scheduleDelivery() }
        if let group = scheduling.1 { scheduleDeadline(for: group) }
    }

    private func scheduleDeadline(for group: TimestampGroup) {
        DispatchQueue.main.asyncAfter(deadline: .now() + presentationDelay) { [weak self] in
            self?.flushTimestampGroup(
                timestamp: group.timestamp,
                generation: group.generation
            )
        }
    }

    private func flushTimestampGroup(timestamp: UInt32, generation: UInt64) {
        let shouldSchedule = lock.withFrameStoreLock {
            guard let group = timestampGroup,
                  group.timestamp == timestamp,
                  group.generation == generation else { return false }
            finalize(group)
            timestampGroup = nil
            return scheduleDeliveryIfNeeded()
        }
        if shouldSchedule { scheduleDelivery() }
    }

    private func finalize(_ group: TimestampGroup) {
        sealedTimestamps.removeValue(forKey: group.timestamp)
        for (tileIndex, frame) in group.frames {
            frames[tileIndex] = frame
            pendingFrames[tileIndex] = frame
        }
    }

    private func isComplete(_ group: TimestampGroup) -> Bool {
        if let sealedTimestamp = sealedTimestamps[group.timestamp] {
            return sealedTimestamp.expectedTileIndices.isSubset(of: group.frames.keys)
        }
        guard let expectedTileCount else { return false }
        return group.frames.count >= expectedTileCount
    }

    private func discardStaleSealedTimestamps() {
        let maximumSealedTimestampCount = 32
        guard sealedTimestamps.count > maximumSealedTimestampCount,
              let oldestTimestamp = sealedTimestamps.min(by: {
                  $0.value.sequence < $1.value.sequence
              })?.key else { return }
        sealedTimestamps.removeValue(forKey: oldestTimestamp)
    }

    private func scheduleDeliveryIfNeeded() -> Bool {
        guard !deliveryScheduled else { return false }
        deliveryScheduled = true
        return true
    }

    private func scheduleDelivery() {
        DispatchQueue.main.async {
            self.deliverPendingFrames()
        }
    }

    @MainActor
    private func deliverPendingFrames() {
        let delivery = lock.withFrameStoreLock {
            let snapshot = frames
            pendingFrames.removeAll(keepingCapacity: true)
            return (snapshot, Array(observers.values))
        }
        if !delivery.0.isEmpty { delivery.1.forEach { $0(delivery.0) } }
        let hasMoreFrames = lock.withFrameStoreLock {
            guard !pendingFrames.isEmpty else {
                deliveryScheduled = false
                return false
            }
            return true
        }
        if hasMoreFrames { scheduleDelivery() }
    }
}

private extension NSLock {
    func withFrameStoreLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
