import Combine
import CoreVideo
import Foundation
import OSLog

final class AppleVideoStream: ObservableObject, @unchecked Sendable {
    enum State: Equatable {
        case preparing
        case streaming
        case failed(String)
        case stopped
    }

    @Published private(set) var state: State = .preparing
    @Published private(set) var canvas: AppleCanvas
    let frames = AppleVideoFrameStore()

    private static let maximumCachedUnitsPerSource = 128
    private static let receiverReportInterval: TimeInterval = 0.5
    private static let logger = Logger(subsystem: "com.wangkai.iShareScreen", category: "VideoFeedback")

    private let receiver: AppleMediaReceiver
    private let processor: AppleHEVCStreamProcessor
    private let feedback: AppleVideoFeedbackController
    private let queue = DispatchQueue(label: "com.isharescreen.video-stream", qos: .userInteractive)
    private let lifecycleLock = NSLock()
    private let countLock = NSLock()
    private var timer: DispatchSourceTimer?
    private var decoder: AppleHEVCDecoder?
    private var sourceToTile = [UInt32: Int]()
    private var cachedUnits = [UInt32: [Data]]()
    private var isClosed = false
    private var frameCount = 0
    private var lastReceiverReportTime: TimeInterval = 0

    init(receiver: AppleMediaReceiver, negotiation: AppleMediaNegotiationResult) throws {
        self.receiver = receiver
        canvas = negotiation.canvas
        processor = try AppleHEVCStreamProcessor(keyBlob: negotiation.keys.videoServer)
        feedback = try AppleVideoFeedbackController(
            sender: receiver,
            keyBlob: negotiation.keys.videoViewer,
            synchronizationSource: negotiation.videoSynchronizationSource
        )
    }

    var decodedFrameCount: Int {
        countLock.withVideoStreamLock { frameCount }
    }

    func reconfigure(canvas: AppleCanvas) async {
        let isOpen = lifecycleLock.withVideoStreamLock { !isClosed }
        guard isOpen else { return }
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                decoder?.close()
                decoder = nil
                sourceToTile.removeAll(keepingCapacity: false)
                cachedUnits.removeAll(keepingCapacity: false)
                processor.reset()
                frames.removeAllFrames()
                countLock.withVideoStreamLock { self.frameCount = 0 }
                DispatchQueue.main.async { [weak self] in
                    self?.canvas = canvas
                    self?.state = .preparing
                    continuation.resume()
                }
            }
        }
    }

    func start() {
        let shouldStart = lifecycleLock.withVideoStreamLock { () -> Bool in
            guard !isClosed, timer == nil else { return false }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            self.timer = timer
            timer.setEventHandler { [weak self] in self?.processAvailablePackets() }
            timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
            timer.activate()
            return true
        }
        if shouldStart { publishState(.preparing) }
    }

    func close() {
        let timer = lifecycleLock.withVideoStreamLock { () -> DispatchSourceTimer? in
            guard !isClosed else { return nil }
            isClosed = true
            defer { self.timer = nil }
            return self.timer
        }
        timer?.cancel()
        queue.async { [weak self] in
            self?.decoder?.close()
            self?.decoder = nil
        }
        publishState(.stopped)
    }

    deinit {
        timer?.cancel()
    }

    private func processAvailablePackets() {
        sendReceiverReportIfNeeded()
        let datagrams = receiver.drainVideoPackets()
        guard !datagrams.isEmpty else { return }
        let accessUnits = processor.process(datagrams)
        sendPendingNACKs()
        guard !accessUnits.isEmpty else { return }

        if decoder == nil || sourceToTile.count != canvas.tileCount {
            cache(accessUnits)
            prepareDecoderIfPossible()
            return
        }
        feed(accessUnits)
    }

    private func cache(_ accessUnits: [AppleHEVCAccessUnit]) {
        for accessUnit in accessUnits {
            var units = cachedUnits[accessUnit.synchronizationSource, default: []]
            units.append(contentsOf: accessUnit.nalUnits)
            if units.count > Self.maximumCachedUnitsPerSource {
                units.removeFirst(units.count - Self.maximumCachedUnitsPerSource)
            }
            cachedUnits[accessUnit.synchronizationSource] = units
        }
    }

    private func prepareDecoderIfPossible() {
        let sources = processor.primarySources(tileCount: canvas.tileCount)
        guard sources.count == canvas.tileCount else { return }
        sourceToTile = Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($1, $0) })
        guard decoder == nil else { return }

        let parameterSets = processor.currentParameterSets()
        guard parameterSets.isComplete else { return }
        do {
            decoder = try AppleHEVCDecoder(parameterSets: parameterSets) { [weak self] tileIndex, frame in
                self?.publish(frame, tileIndex: tileIndex)
            }
            feedCachedUnitsRoundRobin(sources: sources)
        } catch {
            fail(error)
        }
    }

    private func feedCachedUnitsRoundRobin(sources: [UInt32]) {
        let maximumCount = sources.map { cachedUnits[$0]?.count ?? 0 }.max() ?? 0
        for unitIndex in 0..<maximumCount {
            for (tileIndex, source) in sources.enumerated() {
                guard let units = cachedUnits[source], unitIndex < units.count else { continue }
                decode(units[unitIndex], tileIndex: tileIndex)
            }
        }
        cachedUnits.removeAll(keepingCapacity: false)
    }

    private func feed(_ accessUnits: [AppleHEVCAccessUnit]) {
        for accessUnit in accessUnits {
            guard let tileIndex = sourceToTile[accessUnit.synchronizationSource] else { continue }
            for nalUnit in accessUnit.nalUnits {
                decode(nalUnit, tileIndex: tileIndex)
            }
        }
    }

    private func decode(_ nalUnit: Data, tileIndex: Int) {
        do {
            _ = try decoder?.decode(nalUnit, tileIndex: tileIndex)
        } catch AppleHEVCDecoderError.decodeFailed {
            requestKeyFrame(for: tileIndex)
        } catch {
            fail(error)
        }
    }

    private func sendPendingNACKs() {
        do {
            try feedback.sendNACKs(processor.drainMissingSequences())
        } catch {
            Self.logger.debug("NACK send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func requestKeyFrame(for tileIndex: Int) {
        guard let source = sourceToTile.first(where: { $0.value == tileIndex })?.key else { return }
        do {
            try feedback.requestKeyFrame(for: source)
        } catch {
            Self.logger.debug("Key-frame request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func sendReceiverReportIfNeeded() {
        let currentTime = ProcessInfo.processInfo.systemUptime
        guard currentTime - lastReceiverReportTime >= Self.receiverReportInterval else { return }
        lastReceiverReportTime = currentTime
        do {
            try feedback.sendReceiverReport()
        } catch {
            Self.logger.debug("Receiver report failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func publish(_ frame: CVPixelBuffer, tileIndex: Int) {
        frames.publish(frame, at: tileIndex)
        let isFirstFrame = countLock.withVideoStreamLock {
            frameCount += 1
            return frameCount == 1
        }
        if isFirstFrame { publishState(.streaming) }
    }

    private func fail(_ error: Error) {
        timer?.cancel()
        timer = nil
        publishState(.failed(error.localizedDescription))
    }

    private func publishState(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.state = state }
    }
}

protocol AppleVideoStreamStarting {
    func startVideo(for session: RFBAuthenticatedSession, negotiation: AppleMediaNegotiationResult) throws
}

struct AppleVideoStreamStarter: AppleVideoStreamStarting {
    func startVideo(
        for session: RFBAuthenticatedSession,
        negotiation: AppleMediaNegotiationResult
    ) throws {
        guard let receiver = session.mediaReceiver else {
            throw AppleVideoStreamError.missingMediaReceiver
        }
        let stream = try AppleVideoStream(receiver: receiver, negotiation: negotiation)
        session.install(videoStream: stream)
        stream.start()
    }
}

enum AppleVideoStreamError: LocalizedError, Equatable {
    case missingMediaReceiver

    var errorDescription: String? {
        "The remote video receiver is not available."
    }
}

private extension NSLock {
    func withVideoStreamLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
