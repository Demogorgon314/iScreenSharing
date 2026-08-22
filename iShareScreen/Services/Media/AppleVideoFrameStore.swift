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
        let decodedAt: TimeInterval
        let presentationTime: TimeInterval
        let sequence: UInt64
    }

    typealias FrameBatch = [Int: Frame]
    typealias Observer = @MainActor @Sendable (FrameBatch) -> Void

    private let lock = NSLock()
    private var frames = FrameBatch()
    private var pendingFrames = FrameBatch()
    private var nextSequence: UInt64 = 0
    private var deliveryScheduled = false
    private var observers = [UUID: Observer]()

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
        }
    }

    func publish(
        _ pixelBuffer: CVPixelBuffer,
        at tileIndex: Int,
        decodingOrderNumber: UInt16? = nil,
        rtpTimestamp: UInt32? = nil,
        decodedAt: TimeInterval = ProcessInfo.processInfo.systemUptime,
        presentationTime: TimeInterval? = nil
    ) {
        let shouldSchedule = lock.withFrameStoreLock {
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
                decodedAt: decodedAt,
                presentationTime: presentationTime ?? decodedAt,
                sequence: nextSequence
            )
            frames[tileIndex] = frame
            pendingFrames[tileIndex] = frame
            return scheduleDeliveryIfNeeded()
        }
        if shouldSchedule { scheduleDelivery() }
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
