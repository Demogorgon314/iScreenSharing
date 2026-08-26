import AVFAudio
import Combine
import Foundation

final class AppleAudioStream: ObservableObject, @unchecked Sendable {
    @Published private(set) var isMuted: Bool

    private let receiver: any AppleMediaReceiving
    private let decryptor: AppleSRTPDecryptor
    private let decoder: AppleAACELDDecoder
    private let player: any AppleAudioPlaying
    private let didChangeMuted: @MainActor (Bool) -> Void
    private let queue = DispatchQueue(label: "com.isharescreen.audio-stream", qos: .userInteractive)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var isClosed = false
    private var receivedCount = 0
    private var decodedCount = 0
    private var mutedState = false

    init(
        receiver: any AppleMediaReceiving,
        negotiation: AppleMediaNegotiationResult,
        player: (any AppleAudioPlaying)? = nil,
        isMuted: Bool = false,
        didChangeMuted: @escaping @MainActor (Bool) -> Void = { _ in }
    ) throws {
        self.receiver = receiver
        self.isMuted = isMuted
        self.didChangeMuted = didChangeMuted
        mutedState = isMuted
        decryptor = try AppleSRTPDecryptor(keyBlob: negotiation.keys.audioServer)
        let decoder = try AppleAACELDDecoder()
        self.decoder = decoder
        if let player {
            self.player = player
        } else {
            self.player = try AppleAudioPlayer(format: decoder.outputFormat)
        }
        self.player.setMuted(isMuted)
    }

    var receivedPacketCount: Int {
        lock.withAudioStreamLock { receivedCount }
    }

    var decodedPacketCount: Int {
        lock.withAudioStreamLock { decodedCount }
    }

    func start() {
        lock.withAudioStreamLock {
            guard !isClosed, timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            self.timer = timer
            timer.setEventHandler { [weak self] in self?.processAvailablePackets() }
            timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
            timer.activate()
        }
    }

    @MainActor
    func toggleMute() {
        let value = lock.withAudioStreamLock {
            mutedState.toggle()
            return mutedState
        }
        isMuted = value
        player.setMuted(value)
        didChangeMuted(value)
    }

    func close() {
        let timer = lock.withAudioStreamLock { () -> DispatchSourceTimer? in
            guard !isClosed else { return nil }
            isClosed = true
            defer { self.timer = nil }
            return self.timer
        }
        timer?.cancel()
        queue.async { [player] in player.close() }
    }

    deinit {
        timer?.cancel()
    }

    static func isAudioRTP(_ datagram: Data) -> Bool {
        guard datagram.count >= 12, datagram[0] & 0xc0 == 0x80 else { return false }
        let payloadType = datagram[1] & 0x7f
        return payloadType == 101 && !(64...95).contains(payloadType)
    }

    private func processAvailablePackets() {
        for datagram in receiver.drainControlPackets() where Self.isAudioRTP(datagram) {
            guard let packet = try? decryptor.decrypt(datagram) else { continue }
            lock.withAudioStreamLock { receivedCount += 1 }
            do {
                guard let buffer = try decoder.decode(packet.payload) else { continue }
                let shouldPlay = lock.withAudioStreamLock {
                    decodedCount += 1
                    return !mutedState
                }
                if shouldPlay { player.play(buffer) }
            } catch {
                continue
            }
        }
    }
}

private extension NSLock {
    func withAudioStreamLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
