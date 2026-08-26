import AVFAudio
import Foundation

protocol AppleAudioPlaying: AnyObject {
    func play(_ buffer: AVAudioPCMBuffer)
    func setMuted(_ muted: Bool)
    func close()
}

final class AppleAudioPlayer: AppleAudioPlaying, @unchecked Sendable {
    private static let maximumScheduledBuffers = 12

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let lock = NSLock()
    private var scheduledBufferCount = 0
    private var isClosed = false

    init(format: AVAudioFormat) throws {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
    }

    func play(_ buffer: AVAudioPCMBuffer) {
        let shouldSchedule = lock.withAudioPlayerLock {
            guard !isClosed, scheduledBufferCount < Self.maximumScheduledBuffers else { return false }
            scheduledBufferCount += 1
            return true
        }
        guard shouldSchedule else { return }
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            lock.withAudioPlayerLock {
                self.scheduledBufferCount = max(0, self.scheduledBufferCount - 1)
            }
        }
        let hasStartupBuffer = lock.withAudioPlayerLock { scheduledBufferCount >= 3 }
        if hasStartupBuffer, !node.isPlaying { node.play() }
    }

    func setMuted(_ muted: Bool) {
        node.volume = muted ? 0 : 1
    }

    func close() {
        let shouldClose = lock.withAudioPlayerLock {
            guard !isClosed else { return false }
            isClosed = true
            scheduledBufferCount = 0
            return true
        }
        guard shouldClose else { return }
        node.stop()
        engine.stop()
    }

    deinit {
        close()
    }
}

private extension NSLock {
    func withAudioPlayerLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
