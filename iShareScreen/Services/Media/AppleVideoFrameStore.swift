import CoreVideo
import Foundation

final class AppleVideoFrameStore: @unchecked Sendable {
    typealias Observer = @MainActor @Sendable (Int, CVPixelBuffer) -> Void

    private let lock = NSLock()
    private var frames = [Int: CVPixelBuffer]()
    private var pendingFrames = [Int: CVPixelBuffer]()
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
        lock.withFrameStoreLock { frames[tileIndex] }
    }

    func removeAllFrames() {
        lock.withFrameStoreLock {
            frames.removeAll(keepingCapacity: false)
            pendingFrames.removeAll(keepingCapacity: false)
        }
    }

    func publish(_ frame: CVPixelBuffer, at tileIndex: Int) {
        let shouldSchedule = lock.withFrameStoreLock {
            frames[tileIndex] = frame
            pendingFrames[tileIndex] = frame
            guard !deliveryScheduled else { return false }
            deliveryScheduled = true
            return true
        }
        if shouldSchedule { scheduleDelivery() }
    }

    private func scheduleDelivery() {
        DispatchQueue.main.async {
            self.deliverPendingFrames()
        }
    }

    @MainActor
    private func deliverPendingFrames() {
        let delivery = lock.withFrameStoreLock {
            let frames = pendingFrames.sorted { $0.key < $1.key }
            pendingFrames.removeAll(keepingCapacity: true)
            return (frames, Array(observers.values))
        }
        for (tileIndex, frame) in delivery.0 {
            delivery.1.forEach { $0(tileIndex, frame) }
        }
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
