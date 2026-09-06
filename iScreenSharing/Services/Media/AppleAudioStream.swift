import AVFAudio
import Combine
import Foundation
import class ScreenSharingProtocol.AppleSRTPDecryptor

final class AppleAudioStream: ObservableObject, @unchecked Sendable {
    @MainActor @Published private(set) var isMuted = false
    // Pending preparation accepts mute commands just like running playback.
    @MainActor @Published private(set) var isAvailable = true

    struct Playback {
        let decoder: any AppleAudioDecoding
        let player: any AppleAudioPlaying

        static func makeDefault() throws -> Playback {
            let decoder = try AppleAACELDDecoder()
            return Playback(
                decoder: decoder,
                player: try AppleAudioPlayer(format: decoder.outputFormat)
            )
        }
    }

    typealias PlaybackFactory = @Sendable () throws -> Playback

    private enum State {
        case idle, preparing, running, unavailable, closed
    }

    private let receiver: any AppleMediaReceiving
    private let decryptor: AppleSRTPDecryptor
    private let playbackFactory: PlaybackFactory
    private let connectionTiming: ConnectionStartupTrace?
    private let queue = DispatchQueue(label: "com.isharescreen.audio-stream", qos: .userInteractive)
    private let lock = NSLock()
    // Playback creation, use, and disposal all belong to queue.
    private var playback: Playback?
    private var timer: DispatchSourceTimer?
    private var state = State.idle
    private var receivedCount = 0
    private var decodedCount = 0
    private var mutedState = false

    @MainActor
    init(
        receiver: any AppleMediaReceiving,
        negotiation: AppleMediaNegotiationResult,
        connectionTiming: ConnectionStartupTrace? = nil,
        playbackFactory: @escaping PlaybackFactory = { try Playback.makeDefault() }
    ) throws {
        self.receiver = receiver
        self.connectionTiming = connectionTiming
        self.playbackFactory = playbackFactory
        decryptor = try AppleSRTPDecryptor(keyBlob: negotiation.keys.audioServer)
    }

    var receivedPacketCount: Int {
        lock.withAudioStreamLock { receivedCount }
    }

    var decodedPacketCount: Int {
        lock.withAudioStreamLock { decodedCount }
    }

    func start() {
        let shouldStart = lock.withAudioStreamLock {
            guard state == .idle else { return false }
            state = .preparing
            return true
        }
        guard shouldStart else { return }
        queue.async { [weak self] in self?.preparePlayback() }
    }

    @MainActor
    func toggleMute() {
        let value = lock.withAudioStreamLock { () -> Bool? in
            guard state != .closed, state != .unavailable else { return nil }
            mutedState.toggle()
            return mutedState
        }
        guard let value else { return }
        isMuted = value
        queue.async { [weak self] in
            guard let self else { return }
            let muted = self.lock.withAudioStreamLock { self.mutedState }
            self.playback?.player.setMuted(muted)
        }
    }

    func close() {
        let shouldClose = lock.withAudioStreamLock {
            guard state != .closed else { return false }
            state = .closed
            timer?.cancel()
            timer = nil
            return true
        }
        guard shouldClose else { return }
        publishUnavailable()
        queue.async { [self] in
            playback?.player.close()
            playback = nil
        }
    }

    deinit {
        timer?.cancel()
        if let playback {
            queue.async { playback.player.close() }
        }
    }

    static func isAudioRTP(_ datagram: Data) -> Bool {
        guard datagram.count >= 12, datagram[0] & 0xc0 == 0x80 else { return false }
        let payloadType = datagram[1] & 0x7f
        return payloadType == 101 && !(64...95).contains(payloadType)
    }

    private func preparePlayback() {
        guard lock.withAudioStreamLock({ state == .preparing }) else { return }
        do {
            let prepared = try playbackFactory()
            let muted = lock.withAudioStreamLock { mutedState }
            prepared.player.setMuted(muted)
            let installed = lock.withAudioStreamLock {
                // Engine creation cannot be interrupted. A closed session must
                // dispose of its late result without starting packet delivery.
                guard state == .preparing else { return false }
                playback = prepared
                state = .running
                let timer = DispatchSource.makeTimerSource(queue: queue)
                self.timer = timer
                timer.setEventHandler { [weak self] in self?.processAvailablePackets() }
                timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
                connectionTiming?.record(.audioReady, since: .init(.audioStarted))
                timer.activate()
                return true
            }
            if !installed { prepared.player.close() }
        } catch {
            let failed = lock.withAudioStreamLock {
                guard state == .preparing else { return false }
                state = .unavailable
                connectionTiming?.record(.audioUnavailable, since: .init(.audioStarted))
                return true
            }
            if failed { publishUnavailable() }
        }
    }

    private func publishUnavailable() {
        Task { @MainActor [weak self] in self?.isAvailable = false }
    }

    private func processAvailablePackets() {
        guard lock.withAudioStreamLock({ state == .running }), let playback else { return }
        for datagram in receiver.drainControlPackets() where Self.isAudioRTP(datagram) {
            guard lock.withAudioStreamLock({ state == .running }) else { return }
            guard let packet = try? decryptor.decrypt(datagram) else { continue }
            lock.withAudioStreamLock { receivedCount += 1 }
            do {
                guard let buffer = try playback.decoder.decode(packet.payload) else { continue }
                let shouldPlay = lock.withAudioStreamLock {
                    decodedCount += 1
                    return state == .running && !mutedState
                }
                if shouldPlay { playback.player.play(buffer) }
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
