import Combine
import CoreVideo
import Foundation
import OSLog
import QuartzCore

final class AppleVideoStream: ObservableObject, @unchecked Sendable {
    enum State: Equatable {
        case preparing
        case streaming
        case failed(String)
        case stopped
    }

    @Published private(set) var state: State = .preparing
    @Published private(set) var canvas: AppleCanvas
    let frames: AppleVideoFrameStore
    let performance: AppleVideoPerformanceMonitor

    private static let maximumCachedUnitsPerSource = 128
    private static let initialBurstSettleTime: TimeInterval = 0.3
    private static let initialSelectionDeadline: TimeInterval = 2
    private static let minimumInitialPacketCount = 100
    private static let sourceAdoptionStall: TimeInterval = 2
    private static let minimumAdoptionPacketsPerSource = 5
    private static let usesNativePeriodicFeedback =
        ProcessInfo.processInfo.environment["ISHARESCREEN_NATIVE_VIDEO_FEEDBACK"] != "0"
    private static var receiverReportInterval: TimeInterval {
        usesNativePeriodicFeedback ? 1 : 0.5
    }
    private static let initialRecovery = AppleVideoInitialRecoveryPolicy()
    private static let stallRecovery = AppleVideoStallRecoveryPolicy()
    private static let logger = Logger(subsystem: "com.wangkai.iShareScreen", category: "VideoFeedback")

    private let receiver: AppleMediaReceiver
    let displayIndex: Int
    private let mediaStreamIndex: Int
    private let processor: AppleHEVCStreamProcessor
    private let feedback: AppleVideoFeedbackController
    private let queue = DispatchQueue(label: "com.isharescreen.video-stream", qos: .userInteractive)
    private let lifecycleLock = NSLock()
    private let countLock = NSLock()
    private var timer: DispatchSourceTimer?
    private var decoder: AppleHEVCDecoder?
    private var decoderParameterSets: AppleHEVCParameterSets?
    private var sourceToTile = [UInt32: Int]()
    private var abandonedSources = Set<UInt32>()
    private var cachedUnits = [UInt32: [AppleHEVCAccessUnit]]()
    private var decodingOrderQueue = AppleHEVCDecodingOrderQueue()
    private var playoutClock = AppleVideoPlayoutClock()
    private var isClosed = false
    private var frameCount = 0
    private var decodedTiles = Set<Int>()
    private var lastReceiverReportTime: TimeInterval = 0
    private var firstPacketTime: TimeInterval?
    private var initialBurstReadyTime: TimeInterval?
    private var initialPacketCountBaseline = [UInt32: Int]()
    private var lastDecodedFrameTime: TimeInterval = 0
    private var lastVideoPacketTime: TimeInterval = 0
    private var lastInitialKeyFrameRequestTime: TimeInterval = 0
    private var lastStallKeyFrameRequestTime: TimeInterval = 0
    private var lastDecoderRestartTime: TimeInterval = 0

    convenience init(receiver: AppleMediaReceiver, negotiation: AppleMediaNegotiationResult) throws {
        try self.init(receiver: receiver, video: negotiation.videos[0])
    }

    init(receiver: AppleMediaReceiver, video: AppleVideoNegotiation) throws {
        self.receiver = receiver
        mediaStreamIndex = video.mediaStreamIndex
        displayIndex = video.displayIndex
        canvas = video.canvas
        frames = AppleVideoFrameStore()
        performance = AppleVideoPerformanceMonitor(tileCount: video.canvas.tileCount)
        processor = try AppleHEVCStreamProcessor(keyBlob: video.serverKey)
        feedback = try AppleVideoFeedbackController(
            sender: AppleVideoFeedbackSender(receiver: receiver, mediaStreamIndex: video.mediaStreamIndex),
            keyBlob: video.viewerKey,
            synchronizationSource: video.synchronizationSource
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
                decoderParameterSets = nil
                sourceToTile.removeAll(keepingCapacity: false)
                abandonedSources.removeAll(keepingCapacity: false)
                cachedUnits.removeAll(keepingCapacity: false)
                resetDecodingOrder()
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
                lastInitialKeyFrameRequestTime = 0
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
            self?.decoderParameterSets = nil
        }
        publishState(.stopped)
    }

    deinit {
        timer?.cancel()
    }

    private func processAvailablePackets() {
        sendReceiverReportIfNeeded()
        let datagrams = receiver.drainVideoPackets(mediaStreamIndex: mediaStreamIndex)
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
        performance.recordNetwork(
            packetCount: datagrams.count,
            byteCount: datagrams.reduce(0) { $0 + $1.count }
        )
        if firstPacketTime == nil {
            firstPacketTime = ProcessInfo.processInfo.systemUptime
        }
        let accessUnits = processor.process(datagrams)
        performance.recordAccessUnits(accessUnits.count)
        performance.recordAccessUnitBytes(
            accessUnits.reduce(0) { $0 + $1.encodedByteCount },
            intraRefreshCount: accessUnits.filter(\.containsRandomAccessPicture).count
        )
        sendPendingNACKs()
        if decoder == nil { prepareDecoderIfPossible() }
        replaceDecoderForChangedParameterSetsIfNeeded()
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
            units.append(accessUnit)
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
        recoverMissingInitialParameterSetsIfNeeded(now: now)
        prepareDecoder(for: sources)
    }

    private func recoverMissingInitialParameterSetsIfNeeded(now: TimeInterval) {
        let parameterSets = processor.currentParameterSets()
        guard Self.initialRecovery.shouldRequestKeyFrames(
            now: now,
            initialBurstReadyTime: initialBurstReadyTime,
            lastVideoPacketTime: lastVideoPacketTime,
            lastKeyFrameRequestTime: lastInitialKeyFrameRequestTime,
            hasSelectedSources: sourceToTile.count == canvas.tileCount,
            hasCompleteParameterSets: parameterSets.isComplete
        ) else { return }

        lastInitialKeyFrameRequestTime = now
        requestKeyFramesForAllTiles()
    }

    private func prepareDecoder(for sources: [UInt32]) {
        guard decoder == nil else { return }

        let parameterSets = processor.currentParameterSets()
        guard parameterSets.isComplete else { return }
        do {
            decoder = try AppleHEVCDecoder(
                parameterSets: parameterSets,
                tileCount: canvas.tileCount,
                backendHandler: { [weak performance] backend in
                    performance?.setDecoderBackend(backend)
                }
            ) { [weak self] decodedFrame in
                self?.performance.recordDecode(duration: decodedFrame.decodeDuration)
                self?.publish(
                    decodedFrame.pixelBuffer,
                    region: decodedFrame.region,
                    decodingOrderNumber: decodedFrame.decodingOrderNumber,
                    rtpTimestamp: decodedFrame.rtpTimestamp,
                    presentationTime: decodedFrame.presentationTime
                )
            }
            decoderParameterSets = parameterSets
            resetDecodingOrder()
            countLock.withVideoStreamLock {
                self.lastDecodedFrameTime = ProcessInfo.processInfo.systemUptime
            }
            feedCachedUnitsInDecodingOrder(sources: sources)
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
        decoderParameterSets = nil
        resetDecodingOrder()
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
                try decoder?.restartUsingVideoToolboxFallback()
                resetDecodingOrder()
                requestKeyFramesForAllTiles()
            } catch {
                Self.logger.error(
                    "Stalled video decoder restart failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func replaceDecoderForChangedParameterSetsIfNeeded() {
        guard decoder != nil,
              let decoderParameterSets,
              AppleHEVCDecoder.requiresReplacement(
                  configured: decoderParameterSets,
                  current: processor.currentParameterSets()
              ) else { return }
        let sources = sourceToTile.sorted(by: { $0.value < $1.value }).map(\.key)
        decoder?.close()
        decoder = nil
        self.decoderParameterSets = nil
        resetDecodingOrder()
        prepareDecoder(for: sources)
    }

    private func requestKeyFramesForAllTiles() {
        for tileIndex in 0..<canvas.tileCount { requestKeyFrame(for: tileIndex) }
    }

    private func feedCachedUnitsInDecodingOrder(sources: [UInt32]) {
        let accessUnits = sources.flatMap { cachedUnits[$0] ?? [] }
        cachedUnits.removeAll(keepingCapacity: false)
        feed(accessUnits)
    }

    private func feed(_ accessUnits: [AppleHEVCAccessUnit]) {
        let selectedUnits = accessUnits.filter { sourceToTile[$0.synchronizationSource] != nil }
        let output = decodingOrderQueue.enqueue(selectedUnits)
        for accessUnit in output.ready {
            guard let tileIndex = sourceToTile[accessUnit.synchronizationSource] else { continue }
            guard accessUnit.nalUnits.contains(where: Self.isVideoSlice) else { continue }
            let presentationTime = playoutClock.presentationTime(
                for: accessUnit.timestamp,
                hostTime: CACurrentMediaTime()
            )
            decode(
                accessUnit.nalUnits,
                tileIndex: tileIndex,
                decodingOrderNumber: accessUnit.decodingOrderNumber,
                rtpTimestamp: accessUnit.timestamp,
                presentationTime: presentationTime
            )
        }
        if output.requiresRefresh { recoverDecodingOrder() }
    }

    private static func isVideoSlice(_ nalUnit: Data) -> Bool {
        guard let type = AppleHEVCNALUnit.type(of: nalUnit) else { return false }
        return type < 32
    }

    private func resetDecodingOrder() {
        decodingOrderQueue.reset()
        playoutClock.reset()
    }

    private func recoverDecodingOrder() {
        do {
            try decoder?.restart()
            requestKeyFramesForAllTiles()
        } catch {
            fail(error)
        }
    }

    private func decode(
        _ nalUnits: [Data],
        tileIndex: Int,
        decodingOrderNumber: UInt16?,
        rtpTimestamp: UInt32,
        presentationTime: TimeInterval
    ) {
        do {
            _ = try decoder?.decode(
                nalUnits,
                tileIndex: tileIndex,
                decodingOrderNumber: decodingOrderNumber,
                rtpTimestamp: rtpTimestamp,
                presentationTime: presentationTime
            )
        } catch AppleHEVCDecoderError.decodeFailed {
            requestKeyFrame(for: tileIndex)
        } catch {
            fail(error)
        }
    }

    private func sendPendingNACKs() {
        let missingSequences = processor.drainMissingSequences()
        performance.recordNACK(count: missingSequences.values.reduce(0) { $0 + $1.count })
        do {
            try feedback.sendNACKs(missingSequences)
        } catch {
            Self.logger.debug("NACK send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func requestKeyFrame(for tileIndex: Int) {
        guard let source = sourceToTile.first(where: { $0.value == tileIndex })?.key else { return }
        do {
            try feedback.requestKeyFrame(for: source)
            performance.recordKeyFrameRequest()
        } catch {
            Self.logger.debug("Key-frame request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func sendReceiverReportIfNeeded() {
        let currentTime = ProcessInfo.processInfo.systemUptime
        guard currentTime - lastReceiverReportTime >= Self.receiverReportInterval else { return }
        do {
            if Self.usesNativePeriodicFeedback {
                let source = sourceToTile.first(where: { $0.value == 0 })?.key
                    ?? processor.primarySources(tileCount: canvas.tileCount).first
                guard let source,
                      let report = processor.receptionReport(for: source) else { return }
                lastReceiverReportTime = currentTime
                try feedback.sendNativePeriodicFeedback(
                    report: report,
                    refreshSource: source
                )
            } else {
                lastReceiverReportTime = currentTime
                try feedback.sendReceiverReport()
            }
        } catch {
            Self.logger.debug("Receiver report failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func publish(
        _ frame: CVPixelBuffer,
        region: AppleHEVCDecoder.FrameRegion,
        decodingOrderNumber: UInt16?,
        rtpTimestamp: UInt32,
        presentationTime: TimeInterval
    ) {
        let decodedAt = ProcessInfo.processInfo.systemUptime
        let frameIndex: Int
        switch region {
        case let .tile(tileIndex):
            frameIndex = tileIndex
        case .fullCanvas:
            frameIndex = AppleVideoFrameStore.fullCanvasIndex
        }
        frames.publish(
            frame,
            at: frameIndex,
            decodingOrderNumber: decodingOrderNumber,
            rtpTimestamp: rtpTimestamp,
            decodedAt: decodedAt,
            presentationTime: presentationTime
        )
        performance.recordDecodedFrame(rtpTimestamp: rtpTimestamp)
        countLock.withVideoStreamLock {
            self.lastDecodedFrameTime = decodedAt
        }
        if (region == .fullCanvas || frameIndex == 0), let decodingOrderNumber {
            do {
                try feedback.acknowledgeLongTermReference(frameID: decodingOrderNumber)
            } catch {
                Self.logger.debug("LTR acknowledgement failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let becameReady = countLock.withVideoStreamLock {
            frameCount += 1
            let wasReady = decodedTiles.count == canvas.tileCount
            if region == .fullCanvas {
                decodedTiles = Set(0..<canvas.tileCount)
            } else {
                decodedTiles.insert(frameIndex)
            }
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

private final class AppleVideoFeedbackSender: AppleMediaControlSending, @unchecked Sendable {
    private let receiver: AppleMediaReceiver
    private let mediaStreamIndex: Int

    init(receiver: AppleMediaReceiver, mediaStreamIndex: Int) {
        self.receiver = receiver
        self.mediaStreamIndex = mediaStreamIndex
    }

    func sendControl(_ datagram: Data) throws {
        try receiver.sendVideoControl(datagram, mediaStreamIndex: mediaStreamIndex)
    }
}

struct AppleVideoInitialRecoveryPolicy {
    let keyFrameRequestDelay: TimeInterval
    let keyFrameRequestInterval: TimeInterval
    let recentPacketWindow: TimeInterval

    init(
        keyFrameRequestDelay: TimeInterval = 2,
        keyFrameRequestInterval: TimeInterval = 1.5,
        recentPacketWindow: TimeInterval = 1.5
    ) {
        self.keyFrameRequestDelay = keyFrameRequestDelay
        self.keyFrameRequestInterval = keyFrameRequestInterval
        self.recentPacketWindow = recentPacketWindow
    }

    func shouldRequestKeyFrames(
        now: TimeInterval,
        initialBurstReadyTime: TimeInterval?,
        lastVideoPacketTime: TimeInterval,
        lastKeyFrameRequestTime: TimeInterval,
        hasSelectedSources: Bool,
        hasCompleteParameterSets: Bool
    ) -> Bool {
        guard hasSelectedSources,
              !hasCompleteParameterSets,
              let initialBurstReadyTime,
              lastVideoPacketTime > 0,
              now - initialBurstReadyTime >= keyFrameRequestDelay,
              now - lastVideoPacketTime < recentPacketWindow,
              now - lastKeyFrameRequestTime >= keyFrameRequestInterval else { return false }
        return true
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
        let streams = try negotiation.videos.map { try AppleVideoStream(receiver: receiver, video: $0) }
        session.install(videoStreams: streams)
        streams.forEach { $0.start() }
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
