import Combine
import CoreVideo
import Foundation
import OSLog

final class AppleVideoStream: ObservableObject, @unchecked Sendable {
    private struct CachedUnit {
        let data: Data
        let decodingOrderNumber: UInt16?
    }

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
    private static let initialBurstSettleTime: TimeInterval = 0.3
    private static let initialSelectionDeadline: TimeInterval = 2
    private static let minimumInitialPacketCount = 100
    private static let sourceAdoptionStall: TimeInterval = 2
    private static let minimumAdoptionPacketsPerSource = 5
    private static let receiverReportInterval: TimeInterval = 0.5
    private static let stallRecovery = AppleVideoStallRecoveryPolicy()
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
    private var abandonedSources = Set<UInt32>()
    private var cachedUnits = [UInt32: [CachedUnit]]()
    private var isClosed = false
    private var frameCount = 0
    private var decodedTiles = Set<Int>()
    private var lastReceiverReportTime: TimeInterval = 0
    private var firstPacketTime: TimeInterval?
    private var initialBurstReadyTime: TimeInterval?
    private var initialPacketCountBaseline = [UInt32: Int]()
    private var lastDecodedFrameTime: TimeInterval = 0
    private var lastVideoPacketTime: TimeInterval = 0
    private var lastStallKeyFrameRequestTime: TimeInterval = 0
    private var lastDecoderRestartTime: TimeInterval = 0

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
                abandonedSources.removeAll(keepingCapacity: false)
                cachedUnits.removeAll(keepingCapacity: false)
                processor.reset()
                frames.removeAllFrames()
                countLock.withVideoStreamLock {
                    self.frameCount = 0
                    self.decodedTiles.removeAll(keepingCapacity: true)
                }
                firstPacketTime = nil
                initialBurstReadyTime = nil
                initialPacketCountBaseline.removeAll(keepingCapacity: false)
                countLock.withVideoStreamLock { self.lastDecodedFrameTime = 0 }
                lastVideoPacketTime = 0
                lastStallKeyFrameRequestTime = 0
                lastDecoderRestartTime = 0
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
        guard !datagrams.isEmpty else {
            if decoder == nil {
                prepareDecoderIfPossible()
            } else {
                adoptFreshSourcesIfNeeded()
                recoverStalledDecoderIfNeeded()
            }
            return
        }
        lastVideoPacketTime = ProcessInfo.processInfo.systemUptime
        if firstPacketTime == nil {
            firstPacketTime = ProcessInfo.processInfo.systemUptime
        }
        let accessUnits = processor.process(datagrams)
        sendPendingNACKs()
        if decoder == nil { prepareDecoderIfPossible() }
        guard !accessUnits.isEmpty else {
            if decoder != nil {
                adoptFreshSourcesIfNeeded()
                recoverStalledDecoderIfNeeded()
            }
            return
        }

        if decoder == nil || sourceToTile.count != canvas.tileCount {
            cache(accessUnits)
            prepareDecoderIfPossible()
            return
        }
        cache(accessUnits.filter { sourceToTile[$0.synchronizationSource] == nil })
        feed(accessUnits)
        adoptFreshSourcesIfNeeded()
        recoverStalledDecoderIfNeeded()
    }

    private func cache(_ accessUnits: [AppleHEVCAccessUnit]) {
        for accessUnit in accessUnits {
            var units = cachedUnits[accessUnit.synchronizationSource, default: []]
            units.append(contentsOf: accessUnit.nalUnits.map {
                CachedUnit(data: $0, decodingOrderNumber: accessUnit.decodingOrderNumber)
            })
            if units.count > Self.maximumCachedUnitsPerSource {
                units.removeFirst(units.count - Self.maximumCachedUnitsPerSource)
            }
            cachedUnits[accessUnit.synchronizationSource] = units
        }
    }

    private func prepareDecoderIfPossible() {
        guard let firstPacketTime else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if initialBurstReadyTime == nil,
           (processor.totalPacketCount >= Self.minimumInitialPacketCount
            || now - firstPacketTime >= Self.initialSelectionDeadline) {
            initialBurstReadyTime = now
            initialPacketCountBaseline = processor.packetCounts
        }
        guard let initialBurstReadyTime,
              now - initialBurstReadyTime >= Self.initialBurstSettleTime else { return }
        let sources = processor.primarySources(
            tileCount: canvas.tileCount,
            packetCountBaseline: initialPacketCountBaseline
        )
        guard sources.count == canvas.tileCount else { return }
        sourceToTile = Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($1, $0) })
        prepareDecoder(for: sources)
    }

    private func prepareDecoder(for sources: [UInt32]) {
        guard decoder == nil else { return }

        let parameterSets = processor.currentParameterSets()
        guard parameterSets.isComplete else { return }
        do {
            decoder = try AppleHEVCDecoder(parameterSets: parameterSets) { [weak self] tileIndex, decodingOrderNumber, frame in
                self?.publish(frame, tileIndex: tileIndex, decodingOrderNumber: decodingOrderNumber)
            }
            countLock.withVideoStreamLock {
                self.lastDecodedFrameTime = ProcessInfo.processInfo.systemUptime
            }
            feedCachedUnitsRoundRobin(sources: sources)
        } catch {
            fail(error)
        }
    }

    private func adoptFreshSourcesIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        let lastDecodedFrameTime = countLock.withVideoStreamLock { self.lastDecodedFrameTime }
        guard lastDecodedFrameTime > 0,
              now - lastDecodedFrameTime >= Self.sourceAdoptionStall else { return }
        let excluded = Set(sourceToTile.keys).union(abandonedSources)
        let sources = processor.primarySources(tileCount: canvas.tileCount, excluding: excluded)
        guard sources.count == canvas.tileCount,
              sources.allSatisfy({ processor.packetCount(for: [$0]) >= Self.minimumAdoptionPacketsPerSource }) else {
            return
        }

        abandonedSources.formUnion(sourceToTile.keys)
        sourceToTile = Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($1, $0) })
        decoder?.close()
        decoder = nil
        countLock.withVideoStreamLock { self.lastDecodedFrameTime = now }
        prepareDecoder(for: sources)
        for tileIndex in sources.indices { requestKeyFrame(for: tileIndex) }
    }

    private func recoverStalledDecoderIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        let lastDecodedFrameTime = countLock.withVideoStreamLock { self.lastDecodedFrameTime }
        let action = Self.stallRecovery.action(
            now: now,
            lastDecodedFrameTime: lastDecodedFrameTime,
            lastVideoPacketTime: lastVideoPacketTime,
            lastKeyFrameRequestTime: lastStallKeyFrameRequestTime,
            lastDecoderRestartTime: lastDecoderRestartTime
        )
        switch action {
        case .none:
            return
        case .requestKeyFrames:
            lastStallKeyFrameRequestTime = now
            requestKeyFramesForAllTiles()
        case .restartDecoderAndRequestKeyFrames:
            lastDecoderRestartTime = now
            lastStallKeyFrameRequestTime = now
            do {
                try decoder?.restart()
                requestKeyFramesForAllTiles()
            } catch {
                Self.logger.error(
                    "Stalled video decoder restart failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func requestKeyFramesForAllTiles() {
        for tileIndex in 0..<canvas.tileCount { requestKeyFrame(for: tileIndex) }
    }

    private func feedCachedUnitsRoundRobin(sources: [UInt32]) {
        let maximumCount = sources.map { cachedUnits[$0]?.count ?? 0 }.max() ?? 0
        for unitIndex in 0..<maximumCount {
            for (tileIndex, source) in sources.enumerated() {
                guard let units = cachedUnits[source], unitIndex < units.count else { continue }
                let unit = units[unitIndex]
                decode(
                    unit.data,
                    tileIndex: tileIndex,
                    decodingOrderNumber: unit.decodingOrderNumber
                )
            }
        }
        cachedUnits.removeAll(keepingCapacity: false)
    }

    private func feed(_ accessUnits: [AppleHEVCAccessUnit]) {
        for accessUnit in accessUnits {
            guard let tileIndex = sourceToTile[accessUnit.synchronizationSource] else { continue }
            for nalUnit in accessUnit.nalUnits {
                decode(
                    nalUnit,
                    tileIndex: tileIndex,
                    decodingOrderNumber: accessUnit.decodingOrderNumber
                )
            }
        }
    }

    private func decode(_ nalUnit: Data, tileIndex: Int, decodingOrderNumber: UInt16?) {
        do {
            _ = try decoder?.decode(
                nalUnit,
                tileIndex: tileIndex,
                decodingOrderNumber: decodingOrderNumber
            )
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

    private func publish(
        _ frame: CVPixelBuffer,
        tileIndex: Int,
        decodingOrderNumber: UInt16?
    ) {
        frames.publish(frame, at: tileIndex)
        countLock.withVideoStreamLock {
            self.lastDecodedFrameTime = ProcessInfo.processInfo.systemUptime
        }
        if tileIndex == 0, let decodingOrderNumber {
            do {
                try feedback.acknowledgeLongTermReference(frameID: decodingOrderNumber)
            } catch {
                Self.logger.debug("LTR acknowledgement failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let becameReady = countLock.withVideoStreamLock {
            frameCount += 1
            let wasReady = decodedTiles.count == canvas.tileCount
            decodedTiles.insert(tileIndex)
            return !wasReady && decodedTiles.count == canvas.tileCount
        }
        if becameReady {
            publishState(.streaming)
        }
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

struct AppleVideoStallRecoveryPolicy {
    enum Action: Equatable {
        case none
        case requestKeyFrames
        case restartDecoderAndRequestKeyFrames
    }

    let keyFrameRequestDelay: TimeInterval
    let keyFrameRequestInterval: TimeInterval
    let decoderRestartDelay: TimeInterval
    let decoderRestartInterval: TimeInterval
    let recentPacketWindow: TimeInterval

    init(
        keyFrameRequestDelay: TimeInterval = 3,
        keyFrameRequestInterval: TimeInterval = 1.5,
        decoderRestartDelay: TimeInterval = 8,
        decoderRestartInterval: TimeInterval = 8,
        recentPacketWindow: TimeInterval = 1.5
    ) {
        self.keyFrameRequestDelay = keyFrameRequestDelay
        self.keyFrameRequestInterval = keyFrameRequestInterval
        self.decoderRestartDelay = decoderRestartDelay
        self.decoderRestartInterval = decoderRestartInterval
        self.recentPacketWindow = recentPacketWindow
    }

    func action(
        now: TimeInterval,
        lastDecodedFrameTime: TimeInterval,
        lastVideoPacketTime: TimeInterval,
        lastKeyFrameRequestTime: TimeInterval,
        lastDecoderRestartTime: TimeInterval
    ) -> Action {
        guard lastDecodedFrameTime > 0,
              lastVideoPacketTime > 0,
              now - lastVideoPacketTime < recentPacketWindow else { return .none }

        let frameGap = now - lastDecodedFrameTime
        if frameGap >= decoderRestartDelay,
           now - lastDecoderRestartTime >= decoderRestartInterval {
            return .restartDecoderAndRequestKeyFrames
        }
        if frameGap >= keyFrameRequestDelay,
           now - lastKeyFrameRequestTime >= keyFrameRequestInterval {
            return .requestKeyFrames
        }
        return .none
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
