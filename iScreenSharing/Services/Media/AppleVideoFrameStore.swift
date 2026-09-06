import CoreVideo
import Foundation

final class AppleVideoFrameStore: @unchecked Sendable {
    /// A frame at this index already covers the complete remote canvas. Tile
    /// frames and full-canvas frames are mutually exclusive in a snapshot.
    static let fullCanvasIndex = -1

    struct Frame: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let decodingOrderNumber: UInt16?
        let rtpTimestamp: UInt32?
        let accessUnitTiming: AppleHEVCAccessUnit.Timing?
        let decodeEnteredAt: TimeInterval
        let decoderSubmittedAt: TimeInterval
        let decoderOutputAt: TimeInterval
        let playbackHandledAt: TimeInterval
        let decodedAt: TimeInterval
        let presentationTime: TimeInterval
        let sequence: UInt64
    }

    typealias FrameBatch = [Int: Frame]
    typealias Observer = @MainActor @Sendable (FrameBatch) -> Void

    private let lock = NSLock()
    private let preservesLogicalFrameBatches: Bool
    private let logicalFrameQueueCapacity: Int
    private let deliversLogicalFrameBatchesOnDemand: Bool
    private var frames = FrameBatch()
    private var pendingFrames = FrameBatch()
    private var pendingLogicalFrameSnapshots = [FrameBatch]()
    private var nextSequence: UInt64 = 0
    private var deliveryScheduled = false
    private var observers = [UUID: Observer]()

    init(
        preservesLogicalFrameBatches: Bool = false,
        logicalFrameQueueCapacity: Int = 16,
        deliversLogicalFrameBatchesOnDemand: Bool = false
    ) {
        precondition(logicalFrameQueueCapacity > 0)
        precondition(!deliversLogicalFrameBatchesOnDemand || preservesLogicalFrameBatches)
        self.preservesLogicalFrameBatches = preservesLogicalFrameBatches
        self.logicalFrameQueueCapacity = logicalFrameQueueCapacity
        self.deliversLogicalFrameBatchesOnDemand = deliversLogicalFrameBatchesOnDemand
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

    func dequeueLogicalFrameBatch() -> FrameBatch? {
        lock.withFrameStoreLock {
            guard !pendingLogicalFrameSnapshots.isEmpty else { return nil }
            return pendingLogicalFrameSnapshots.removeFirst()
        }
    }

    /// Transfers the bounded pending snapshots atomically. The latest stored
    /// canvas remains available, including unchanged tiles from earlier frames.
    func drainLogicalFrameBatches() -> [FrameBatch] {
        lock.withFrameStoreLock {
            let batches = pendingLogicalFrameSnapshots
            pendingLogicalFrameSnapshots.removeAll(keepingCapacity: true)
            return batches
        }
    }

    var pendingLogicalFrameBatchCount: Int {
        lock.withFrameStoreLock { pendingLogicalFrameSnapshots.count }
    }

    func removeAllFrames() {
        lock.withFrameStoreLock {
            frames.removeAll(keepingCapacity: false)
            pendingFrames.removeAll(keepingCapacity: false)
            pendingLogicalFrameSnapshots.removeAll(keepingCapacity: false)
        }
    }

    func publish(
        _ pixelBuffer: CVPixelBuffer,
        at tileIndex: Int,
        decodingOrderNumber: UInt16? = nil,
        rtpTimestamp: UInt32? = nil,
        accessUnitTiming: AppleHEVCAccessUnit.Timing? = nil,
        decodeEnteredAt: TimeInterval? = nil,
        decoderSubmittedAt: TimeInterval? = nil,
        decoderOutputAt: TimeInterval? = nil,
        playbackHandledAt: TimeInterval? = nil,
        decodedAt: TimeInterval = ProcessInfo.processInfo.systemUptime,
        presentationTime: TimeInterval? = nil
    ) {
        let shouldSchedule = lock.withFrameStoreLock {
            store(
                pixelBuffer: pixelBuffer,
                at: tileIndex,
                decodingOrderNumber: decodingOrderNumber,
                rtpTimestamp: rtpTimestamp,
                accessUnitTiming: accessUnitTiming,
                decodeEnteredAt: decodeEnteredAt ?? decoderSubmittedAt ?? decoderOutputAt ?? decodedAt,
                decoderSubmittedAt: decoderSubmittedAt ?? decoderOutputAt ?? decodedAt,
                decoderOutputAt: decoderOutputAt ?? decodedAt,
                playbackHandledAt: playbackHandledAt ?? decodedAt,
                decodedAt: decodedAt,
                presentationTime: presentationTime ?? decodedAt
            )
            return scheduleDeliveryIfNeeded()
        }
        if shouldSchedule { scheduleDelivery() }
    }

    /// Publishes every tile in one logical sender frame as one observable
    /// snapshot. Observers can never see an intermediate subset of this batch.
    func publish(
        _ decodedFrames: [AppleHEVCDecoder.DecodedFrame],
        playbackHandledAt: TimeInterval
    ) {
        guard !decodedFrames.isEmpty else { return }
        let shouldSchedule = lock.withFrameStoreLock {
            for decodedFrame in decodedFrames {
                let tileIndex: Int
                switch decodedFrame.region {
                case let .tile(index):
                    tileIndex = index
                case .fullCanvas:
                    tileIndex = Self.fullCanvasIndex
                }
                store(
                    pixelBuffer: decodedFrame.pixelBuffer,
                    at: tileIndex,
                    decodingOrderNumber: decodedFrame.decodingOrderNumber,
                    rtpTimestamp: decodedFrame.rtpTimestamp,
                    accessUnitTiming: decodedFrame.accessUnitTiming,
                    decodeEnteredAt: decodedFrame.decodeEnteredAt,
                    decoderSubmittedAt: decodedFrame.decoderSubmittedAt,
                    decoderOutputAt: decodedFrame.decoderOutputAt,
                    playbackHandledAt: playbackHandledAt,
                    decodedAt: playbackHandledAt,
                    presentationTime: decodedFrame.presentationTime
                )
            }
            if preservesLogicalFrameBatches {
                pendingFrames.removeAll(keepingCapacity: true)
                if pendingLogicalFrameSnapshots.count == logicalFrameQueueCapacity {
                    pendingLogicalFrameSnapshots.removeFirst()
                }
                pendingLogicalFrameSnapshots.append(frames)
            }
            return deliversLogicalFrameBatchesOnDemand ? false : scheduleDeliveryIfNeeded()
        }
        if shouldSchedule { scheduleDelivery() }
    }

    private func store(
        pixelBuffer: CVPixelBuffer,
        at tileIndex: Int,
        decodingOrderNumber: UInt16?,
        rtpTimestamp: UInt32?,
        accessUnitTiming: AppleHEVCAccessUnit.Timing?,
        decodeEnteredAt: TimeInterval,
        decoderSubmittedAt: TimeInterval,
        decoderOutputAt: TimeInterval,
        playbackHandledAt: TimeInterval,
        decodedAt: TimeInterval,
        presentationTime: TimeInterval
    ) {
        if tileIndex == Self.fullCanvasIndex {
            frames.removeAll(keepingCapacity: true)
            pendingFrames.removeAll(keepingCapacity: true)
        } else if frames.removeValue(forKey: Self.fullCanvasIndex) != nil {
            pendingFrames.removeValue(forKey: Self.fullCanvasIndex)
        }
        nextSequence &+= 1
        let frame = Frame(
            pixelBuffer: pixelBuffer,
            decodingOrderNumber: decodingOrderNumber,
            rtpTimestamp: rtpTimestamp,
            accessUnitTiming: accessUnitTiming,
            decodeEnteredAt: decodeEnteredAt,
            decoderSubmittedAt: decoderSubmittedAt,
            decoderOutputAt: decoderOutputAt,
            playbackHandledAt: playbackHandledAt,
            decodedAt: decodedAt,
            presentationTime: presentationTime,
            sequence: nextSequence
        )
        frames[tileIndex] = frame
        pendingFrames[tileIndex] = frame
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
            let snapshot: FrameBatch
            if !pendingLogicalFrameSnapshots.isEmpty {
                snapshot = pendingLogicalFrameSnapshots.removeFirst()
            } else {
                snapshot = frames
                pendingFrames.removeAll(keepingCapacity: true)
            }
            return (snapshot, Array(observers.values))
        }
        if !delivery.0.isEmpty { delivery.1.forEach { $0(delivery.0) } }
        let hasMoreFrames = lock.withFrameStoreLock {
            guard !pendingLogicalFrameSnapshots.isEmpty || !pendingFrames.isEmpty else {
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
