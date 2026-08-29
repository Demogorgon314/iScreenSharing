import Foundation
import enum ScreenSharingProtocol.AppleCursorUpdate
import struct ScreenSharingProtocol.AppleCursorImage

final class AppleCursorStore: @unchecked Sendable {
    typealias Observer = @MainActor @Sendable (AppleCursorImage?) -> Void

    private static let maximumCacheEntries = 64
    private let lock = NSLock()
    private var cache = [UInt32: AppleCursorImage]()
    private var cacheOrder = [UInt32]()
    private var selectedImage: AppleCursorImage?
    private var updateCount = 0
    private var observers = [UUID: Observer]()

    @discardableResult
    func addObserver(_ observer: @escaping Observer) -> UUID {
        lock.withCursorStoreLock {
            let identifier = UUID()
            observers[identifier] = observer
            return identifier
        }
    }

    func removeObserver(_ identifier: UUID) {
        _ = lock.withCursorStoreLock { observers.removeValue(forKey: identifier) }
    }

    func currentImage() -> AppleCursorImage? {
        lock.withCursorStoreLock { selectedImage }
    }

    var receivedUpdateCount: Int {
        lock.withCursorStoreLock { updateCount }
    }

    func apply(_ update: AppleCursorUpdate) {
        let result = lock.withCursorStoreLock { () -> (AppleCursorImage?, [Observer]) in
            updateCount += 1
            switch update {
            case .store(let id, let image):
                cache[id] = image
                cacheOrder.removeAll { $0 == id }
                cacheOrder.append(id)
                while cacheOrder.count > Self.maximumCacheEntries {
                    cache.removeValue(forKey: cacheOrder.removeFirst())
                }
                selectedImage = image
            case .select(let id):
                selectedImage = cache[id]
            }
            return (selectedImage, Array(observers.values))
        }
        DispatchQueue.main.async {
            result.1.forEach { $0(result.0) }
        }
    }
}

private extension NSLock {
    func withCursorStoreLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
