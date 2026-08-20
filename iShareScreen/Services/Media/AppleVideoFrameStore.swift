import CoreVideo
import Foundation

final class AppleVideoFrameStore: @unchecked Sendable {
    typealias Observer = @MainActor @Sendable (Int, CVPixelBuffer) -> Void

    private let lock = NSLock()
    private var frames = [Int: CVPixelBuffer]()
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

    func publish(_ frame: CVPixelBuffer, at tileIndex: Int) {
        let callbacks = lock.withFrameStoreLock {
            frames[tileIndex] = frame
            return Array(observers.values)
        }
        DispatchQueue.main.async {
            callbacks.forEach { $0(tileIndex, frame) }
        }
    }
}

private extension NSLock {
    func withFrameStoreLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
