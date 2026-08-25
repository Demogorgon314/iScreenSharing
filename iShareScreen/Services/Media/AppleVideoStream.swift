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
    private var mediaCanvas: AppleCanvas
    let frames: AppleVideoFrameStore
    let performance: AppleVideoPerformanceMonitor

    private static let maximumCachedUnitsPerSource = 128
    private static let initialBurstSettleTime: TimeInterval = 0.3
    private static let initialSelectionDeadline: TimeInterval = 2
    private static let minimumInitialPacketCount = 100
    private static let sourceAdoptionStall: TimeInterval = 2
    private static let minimumAdoptionPacketsPerSource = 5
    private static let receiverReportInterval: TimeInterval = 1
    private static let initialRecovery = AppleVideoInitialRecoveryPolicy()
    private static let stallRecovery = AppleVideoStallRecoveryPolicy()
    private static let logger = Logger(subsystem: "com.wangkai.iShareScreen", category: "VideoFeedback")

    private let receiver: AppleMediaReceiver
    let displayIndex: Int
    private let mediaStreamIndex: Int
    private let processor: AppleHEVCStreamProcessor
    private let feedback: AppleVideoFeedbackController
    private let rateControlMode: AppleVideoRateControlMode
    private let qualityDiagnosticsEnabled: Bool
    private let networkQueue = DispatchQueue(
        label: "com.isharescreen.video-stream.network",
        qos: .userInteractive
    )
    private let queue = DispatchQueue(
        label: "com.isharescreen.video-stream.playback",
        qos: .userInteractive
    )
    private let feedbackQueue = DispatchQueue(
        label: "com.isharescreen.video-stream.feedback",
        qos: .userInteractive
    )
    private let lifecycleLock = NSLock()
    private let countLock = NSLock()
    private var playbackTimer: DispatchSourceTimer?
    private var rateControlTimer: DispatchSourceTimer?
    private var decodePipeline: AppleHEVCDecodePipeline?
    private var decoderParameterSets: AppleHEVCParameterSets?
    private var sourceToTile = [UInt32: Int]()
    private var abandonedSources = Set<UInt32>()
    private var cachedUnits = [UInt32: [AppleHEVCAccessUnit]]()
    private var isClosed = false
    private var mediaGeneration: UInt64 = 0
    private var frameCount = 0
    private var decodedTiles = Set<Int>()
    private var lastReceiverReportTime: TimeInterval = 0
    private var firstPacketTime: TimeInterval?
    private var initialBurstReadyTime: TimeInterval?
    private var initialPacketCountBaseline = [UInt32: Int]()
    private var lastDecodedFrameTime: TimeInterval = 0
    private var playbackWatchdogStartTime: TimeInterval = 0
    private var lastVideoPacketTime: TimeInterval = 0
    private var latestReceiveQueueDelayMilliseconds = 0.0
    private var lastInitialKeyFrameRequestTime: TimeInterval = 0
    private var lastStallKeyFrameRequestTime: TimeInterval = 0
    private var refreshScheduler = AppleVideoRefreshScheduler()

    convenience init(receiver: AppleMediaReceiver, negotiation: AppleMediaNegotiationResult) throws {
        try self.init(receiver: receiver, video: negotiation.videos[0])
    }

    init(receiver: AppleMediaReceiver, video: AppleVideoNegotiation) throws {
        self.receiver = receiver
        mediaStreamIndex = video.mediaStreamIndex
        displayIndex = video.displayIndex
        canvas = video.canvas
        mediaCanvas = video.canvas
        frames = AppleVideoFrameStore()
        performance = AppleVideoPerformanceMonitor(tileCount: video.canvas.tileCount)
        performance.setSocketReceiveBufferBytes(
            receiver.videoReceiveBufferConfiguration(
                mediaStreamIndex: video.mediaStreamIndex
            )?.actualBytes
        )
        processor = try AppleHEVCStreamProcessor(keyBlob: video.serverKey)
        let environment = ProcessInfo.processInfo.environment
        rateControlMode = AppleVideoRateControlMode(
            environmentValue: environment["ISHARESCREEN_RCTL_MODE"]
        )
        qualityDiagnosticsEnabled = environment["ISHARESCREEN_QUALITY_DIAGNOSTICS"] == "1"
        feedback = try AppleVideoFeedbackController(
            sender: AppleVideoFeedbackSender(receiver: receiver, mediaStreamIndex: video.mediaStreamIndex),
            keyBlob: video.viewerKey,
            synchronizationSource: video.synchronizationSource
        )
    }

    var decodedFrameCount: Int {
        countLock.withVideoStreamLock { frameCount }
    }

    /// Updates presentation geometry without disturbing the active media
    /// generation or the last frame retained by the renderer.
    func updateCanvas(_ canvas: AppleCanvas) async {
        let isOpen = lifecycleLock.withVideoStreamLock { !isClosed }
        guard isOpen else { return }
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                let isOpen = self.lifecycleLock.withVideoStreamLock { !self.isClosed }
                guard isOpen else {
                    continuation.resume()
                    return
                }
                self.networkQueue.sync {
                    self.mediaCanvas = canvas
                }
                DispatchQueue.main.async { [weak self] in
                    self?.canvas = canvas
                    continuation.resume()
                }
            }
        }
    }

    /// Starts a fresh receive/decode generation while leaving the last decoded
    /// frame visible. The current server requires a media configuration replay
    /// after changing its virtual display, which restarts the RTP stream even
    /// though the connection and rendering surface remain the same.
    func prepareForMediaRestart() async {
        let isOpen = lifecycleLock.withVideoStreamLock { !isClosed }
        guard isOpen else { return }
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                let isOpen = self.lifecycleLock.withVideoStreamLock { !self.isClosed }
                guard isOpen else {
                    continuation.resume()
                    return
                }

                self.networkQueue.sync {
                    self.lifecycleLock.withVideoStreamLock {
                        self.mediaGeneration &+= 1
                    }
                    self.processor.reset()
                    self.lastReceiverReportTime = 0
                }
                self.decodePipeline?.close()
                self.decodePipeline = nil
                self.decoderParameterSets = nil
                self.sourceToTile.removeAll(keepingCapacity: false)
                self.abandonedSources.removeAll(keepingCapacity: false)
                self.cachedUnits.removeAll(keepingCapacity: false)
                self.countLock.withVideoStreamLock {
                    self.firstPacketTime = nil
                    self.lastDecodedFrameTime = 0
                    self.lastVideoPacketTime = 0
                    self.latestReceiveQueueDelayMilliseconds = 0
                }
                self.initialBurstReadyTime = nil
                self.initialPacketCountBaseline.removeAll(keepingCapacity: false)
                self.lastInitialKeyFrameRequestTime = 0
                self.lastStallKeyFrameRequestTime = 0
                self.playbackWatchdogStartTime = 0
                self.refreshScheduler.reset()
                continuation.resume()
            }
        }
    }

    func start() {
        let canStart = lifecycleLock.withVideoStreamLock {
            !isClosed && playbackTimer == nil && rateControlTimer == nil
        }
        guard canStart else { return }
        do {
            try receiver.startVideoDelivery(
                mediaStreamIndex: mediaStreamIndex,
                on: networkQueue
            ) { [weak self] datagram in
                self?.processNetworkDatagram(datagram)
            }
        } catch {
            fail(error)
            return
        }
        let shouldStart = lifecycleLock.withVideoStreamLock { () -> Bool in
            guard !isClosed, playbackTimer == nil, rateControlTimer == nil else { return false }
            let playbackTimer = DispatchSource.makeTimerSource(queue: queue)
            let rateControlTimer = DispatchSource.makeTimerSource(queue: feedbackQueue)
            self.playbackTimer = playbackTimer
            self.rateControlTimer = rateControlTimer
            playbackTimer.setEventHandler { [weak self] in self?.processPeriodicTasks() }
            rateControlTimer.setEventHandler { [weak self] in
                self?.sendRateControlFeedback()
            }
            playbackTimer.schedule(
                deadline: .now(),
                repeating: .milliseconds(50),
                leeway: .milliseconds(10)
            )
            rateControlTimer.schedule(
                deadline: .now(),
                repeating: .milliseconds(50),
                leeway: .milliseconds(10)
            )
            playbackTimer.activate()
            rateControlTimer.activate()
            return true
        }
        if shouldStart {
            publishState(.preparing)
        } else {
            receiver.stopVideoDelivery(mediaStreamIndex: mediaStreamIndex)
        }
    }

    func close() {
        let timers = lifecycleLock.withVideoStreamLock { () -> (
            DispatchSourceTimer?,
            DispatchSourceTimer?
        )? in
            guard !isClosed else { return nil }
            isClosed = true
            mediaGeneration &+= 1
            defer {
                self.playbackTimer = nil
                self.rateControlTimer = nil
            }
            return (self.playbackTimer, self.rateControlTimer)
        }
        receiver.stopVideoDelivery(mediaStreamIndex: mediaStreamIndex)
        timers?.0?.cancel()
        timers?.1?.cancel()
        queue.async { [weak self] in
            self?.decodePipeline?.close()
            self?.decodePipeline = nil
            self?.decoderParameterSets = nil
        }
        publishState(.stopped)
    }

    deinit {
        playbackTimer?.cancel()
        rateControlTimer?.cancel()
    }

    private func processPeriodicTasks() {
        processor.expireIncompleteAccessUnits(at: ProcessInfo.processInfo.systemUptime)
        if decodePipeline == nil {
            prepareDecoderIfPossible()
        } else {
            adoptFreshSourcesIfNeeded()
            recoverStalledDecoderIfNeeded()
        }
    }

    private func processNetworkDatagram(_ datagram: AppleReceivedVideoDatagram) {
        let generation = lifecycleLock.withVideoStreamLock { () -> UInt64? in
            guard !isClosed else { return nil }
            return mediaGeneration
        }
        guard let generation else { return }
        let processingTime = ProcessInfo.processInfo.systemUptime
        countLock.withVideoStreamLock {
            self.lastVideoPacketTime = processingTime
            self.latestReceiveQueueDelayMilliseconds = max(
                0,
                (processingTime - datagram.arrivalTime) * 1_000
            )
            if self.firstPacketTime == nil {
                self.firstPacketTime = processingTime
            }
        }
        performance.recordNetwork(
            packetCount: 1,
            byteCount: datagram.data.count,
            estimatedSocketBacklogBytes: datagram.estimatedSocketBacklogBytes,
            receiveDrainDuration: processingTime - datagram.receiveBatchStartedAt
        )
        let accessUnit = processor.process(datagram)
        sendReceiverReportIfNeeded()
        sendPendingNACKs()
        sendFrameLossFeedbackIfNeeded()
        guard let accessUnit else { return }
        queue.async { [weak self] in
            self?.process(accessUnit, generation: generation)
        }
    }

    private func process(_ accessUnit: AppleHEVCAccessUnit, generation: UInt64) {
        let isCurrentGeneration = lifecycleLock.withVideoStreamLock {
            !isClosed && mediaGeneration == generation
        }
        guard isCurrentGeneration else { return }
        let accessUnits = [accessUnit]
        performance.recordAccessUnits(1)
        performance.recordAccessUnitBytes(
            accessUnit.encodedByteCount,
            intraRefreshCount: accessUnit.containsRandomAccessPicture ? 1 : 0
        )
        if decodePipeline == nil { prepareDecoderIfPossible() }
        replaceDecoderForChangedParameterSetsIfNeeded()

        if decodePipeline == nil || sourceToTile.count != mediaCanvas.tileCount {
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
        guard let firstPacketTime = countLock.withVideoStreamLock({ self.firstPacketTime }) else {
            return
        }
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
            tileCount: mediaCanvas.tileCount,
            packetCountBaseline: initialPacketCountBaseline
        )
        guard sources.count == mediaCanvas.tileCount else { return }
        sourceToTile = Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($1, $0) })
        recoverMissingInitialParameterSetsIfNeeded(now: now)
        prepareDecoder(for: sources)
    }

    private func recoverMissingInitialParameterSetsIfNeeded(now: TimeInterval) {
        let parameterSets = processor.currentParameterSets()
        let lastVideoPacketTime = countLock.withVideoStreamLock { self.lastVideoPacketTime }
        guard Self.initialRecovery.shouldRequestKeyFrames(
            now: now,
            initialBurstReadyTime: initialBurstReadyTime,
            lastVideoPacketTime: lastVideoPacketTime,
            lastKeyFrameRequestTime: lastInitialKeyFrameRequestTime,
            hasSelectedSources: sourceToTile.count == mediaCanvas.tileCount,
            hasCompleteParameterSets: parameterSets.isComplete
        ) else { return }

        lastInitialKeyFrameRequestTime = now
        scheduleKeyFramesForAllTiles()
    }

    private func prepareDecoder(for sources: [UInt32]) {
        guard decodePipeline == nil else { return }

        let parameterSets = processor.currentParameterSets()
        guard parameterSets.isComplete else { return }
        let tileCount = mediaCanvas.tileCount
        let performanceMonitor = performance
        do {
            decodePipeline = try AppleHEVCDecodePipeline(
                tileCount: tileCount,
                sourceToTile: sourceToTile,
                callbackQueue: queue,
                decoderFactory: makeDecoderFactory(
                    parameterSets: parameterSets,
                    tileCount: tileCount,
                    performanceMonitor: performanceMonitor
                ),
                frameHandler: { [weak self] decodedFrame in
                    self?.performance.recordDecode(duration: decodedFrame.decodeDuration)
                    self?.publish(
                        decodedFrame.pixelBuffer,
                        region: decodedFrame.region,
                        decodingOrderNumber: decodedFrame.decodingOrderNumber,
                        rtpTimestamp: decodedFrame.rtpTimestamp,
                        presentationTime: decodedFrame.presentationTime,
                        accessUnitTiming: decodedFrame.accessUnitTiming,
                        decodeEnteredAt: decodedFrame.decodeEnteredAt,
                        decoderSubmittedAt: decodedFrame.decoderSubmittedAt,
                        decoderOutputAt: decodedFrame.decoderOutputAt
                    )
                },
                longTermReferenceHandler: { [weak self] decodingOrderNumber in
                    do {
                        try self?.feedback.acknowledgeLongTermReference(
                            decodingOrderNumber: decodingOrderNumber
                        )
                    } catch {
                        Self.logger.debug(
                            "LTR acknowledgement failed: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                },
                refreshHandler: { [weak self] timestamp in
                    self?.scheduleKeyFramesForAllTiles(timestamp: timestamp)
                },
                errorHandler: { [weak self] error in self?.fail(error) }
            )
            decoderParameterSets = parameterSets
            countLock.withVideoStreamLock {
                self.lastDecodedFrameTime = ProcessInfo.processInfo.systemUptime
            }
            playbackWatchdogStartTime = ProcessInfo.processInfo.systemUptime
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
        let sources = processor.primarySources(tileCount: mediaCanvas.tileCount, excluding: excluded)
        guard sources.count == mediaCanvas.tileCount,
              sources.allSatisfy({ processor.packetCount(for: [$0]) >= Self.minimumAdoptionPacketsPerSource }) else {
            return
        }

        abandonedSources.formUnion(sourceToTile.keys)
        sourceToTile = Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($1, $0) })
        decodePipeline?.close()
        decodePipeline = nil
        decoderParameterSets = nil
        countLock.withVideoStreamLock { self.lastDecodedFrameTime = now }
        prepareDecoder(for: sources)
        scheduleKeyFramesForAllTiles()
    }

    private func recoverStalledDecoderIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        let lastVideoPacketTime = countLock.withVideoStreamLock { self.lastVideoPacketTime }
        let lastDisplayedFrameTime = max(
            playbackWatchdogStartTime,
            performance.mostRecentDisplayTime ?? 0
        )
        let action = Self.stallRecovery.action(
            now: now,
            lastDisplayedFrameTime: lastDisplayedFrameTime,
            lastVideoPacketTime: lastVideoPacketTime,
            lastKeyFrameRequestTime: lastStallKeyFrameRequestTime
        )
        switch action {
        case .none:
            return
        case .requestKeyFrames:
            lastStallKeyFrameRequestTime = now
            decodePipeline?.resetDecodingOrder()
            scheduleWatchdogKeyFrameRequest()
        }
    }

    private func replaceDecoderForChangedParameterSetsIfNeeded() {
        guard let decodePipeline,
              let decoderParameterSets,
              AppleHEVCDecoder.requiresReplacement(
                  configured: decoderParameterSets,
                  current: processor.currentParameterSets()
              ) else { return }
        let parameterSets = processor.currentParameterSets()
        do {
            try decodePipeline.replaceDecoder(using: makeDecoderFactory(
                parameterSets: parameterSets,
                tileCount: mediaCanvas.tileCount,
                performanceMonitor: performance
            ))
            self.decoderParameterSets = parameterSets
        } catch {
            fail(error)
        }
    }

    private func makeDecoderFactory(
        parameterSets: AppleHEVCParameterSets,
        tileCount: Int,
        performanceMonitor: AppleVideoPerformanceMonitor
    ) -> AppleHEVCDecodePipeline.DecoderFactory {
        { failureHandler, frameHandler, longTermReferenceHandler in
            try AppleHEVCDecoder(
                parameterSets: parameterSets,
                tileCount: tileCount,
                backendHandler: { backend in
                    performanceMonitor.setDecoderBackend(backend)
                },
                failureHandler: failureHandler,
                longTermReferenceHandler: longTermReferenceHandler,
                frameHandler: frameHandler
            )
        }
    }

    private func scheduleKeyFramesForAllTiles(timestamp: UInt32? = nil) {
        processor.discardBufferedAccessUnits()
        cachedUnits.removeAll(keepingCapacity: false)
        guard refreshScheduler.accept(
            timestamp: timestamp ?? processor.currentPlayoutTimestamp
        ) else { return }
        requestKeyFrame()
    }

    private func scheduleWatchdogKeyFrameRequest() {
        guard refreshScheduler.accept(timestamp: nil) else { return }
        requestKeyFrame()
    }

    private func feedCachedUnitsInDecodingOrder(sources: [UInt32]) {
        let accessUnits = sources.flatMap { cachedUnits[$0] ?? [] }
        cachedUnits.removeAll(keepingCapacity: false)
        feed(accessUnits)
    }

    private func feed(_ accessUnits: [AppleHEVCAccessUnit]) {
        decodePipeline?.submit(accessUnits)
    }

    private func sendPendingNACKs() {
        let currentTime = ProcessInfo.processInfo.systemUptime
        let missingSequences = processor.missingSequencesDueForNACK(at: currentTime)
        guard !missingSequences.isEmpty else { return }
        do {
            try feedback.sendNACKs(missingSequences)
            processor.markNACKsSent(missingSequences, at: currentTime)
            performance.recordNACK(count: missingSequences.values.reduce(0) { $0 + $1.count })
        } catch {
            Self.logger.debug("NACK send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func requestKeyFrame() {
        guard let source = sourceToTile.first(where: { $0.value == 0 })?.key
            ?? sourceToTile.keys.min() else { return }
        do {
            try feedback.requestKeyFrame(for: source)
            performance.recordKeyFrameRequest()
        } catch {
            Self.logger.debug("Key-frame request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func sendFrameLossFeedbackIfNeeded() {
        let currentTime = ProcessInfo.processInfo.systemUptime
        let pending = processor.frameLossFeedbackDue(at: currentTime)
        for loss in pending {
            do {
                try feedback.sendFrameLossFeedback(
                    mediaSource: loss.mediaSource,
                    rtpTimestamp: loss.rtpTimestamp,
                    packedLoss: loss.packedLoss,
                    framePacketCount: loss.wirePacketCount,
                    frameLostPacketCount: loss.wireLostPacketCount
                )
                processor.markFrameLossFeedbackSent(loss, at: currentTime)
                if qualityDiagnosticsEnabled {
                    Self.logger.notice(
                        "[DEBUG-LOSS-ALFB-74C1] source=\(loss.mediaSource, format: .hex) rtp=\(loss.rtpTimestamp) expected=\(loss.expectedPacketCount) lost=\(loss.lostPacketCount)"
                    )
                }
            } catch {
                Self.logger.debug(
                    "Frame-loss feedback failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func sendReceiverReportIfNeeded() {
        let currentTime = ProcessInfo.processInfo.systemUptime
        guard currentTime - lastReceiverReportTime >= Self.receiverReportInterval else { return }
        do {
            let source = sourceToTile.first(where: { $0.value == 0 })?.key
                ?? processor.primarySources(tileCount: mediaCanvas.tileCount).first
            guard let source,
                  let report = processor.receptionReport(for: source) else { return }
            lastReceiverReportTime = currentTime
            performance.recordReceptionReport(
                fractionLost: report.fractionLost,
                cumulativePacketsLost: report.cumulativePacketsLost,
                interarrivalJitterMilliseconds: Double(report.interarrivalJitter) / 24
            )
            try feedback.sendReceiverReport(report: report)
        } catch {
            Self.logger.debug("Receiver report failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func sendRateControlFeedback() {
        let isOpen = lifecycleLock.withVideoStreamLock { !isClosed }
        guard isOpen else { return }
        let currentTime = ProcessInfo.processInfo.systemUptime
        guard let estimatedInfo = processor.rateControlFeedback(at: currentTime),
              let info = rateControlMode.apply(to: estimatedInfo) else { return }
        do {
            try feedback.sendRateControl(mediaControlInfo: info.serialized())
            if qualityDiagnosticsEnabled {
                let diagnostics = processor.rateControlDiagnostics()
                let receiveQueueDelayMilliseconds = countLock.withVideoStreamLock {
                    self.latestReceiveQueueDelayMilliseconds
                }
                Self.logger.notice(
                    "[DEBUG-QUALITY-5C4E] mode=\(String(describing: self.rateControlMode), privacy: .public) wireBWE=\(Double(info.estimatedBandwidthKilobitsPerSecond) / 1_000, format: .fixed(precision: 3))Mbps estimatedBWE=\(Double(estimatedInfo.estimatedBandwidthKilobitsPerSecond) / 1_000, format: .fixed(precision: 3))Mbps candidate=\(diagnostics.candidateBandwidthMegabitsPerSecond, format: .fixed(precision: 3))Mbps probe=\(diagnostics.probeDurationMilliseconds, format: .fixed(precision: 3))ms/\(diagnostics.probeBytesAfterReference)B state=\(diagnostics.estimateState, privacy: .public) pending=\(diagnostics.pendingSampleCount) rtpDelta=\(diagnostics.timestampDelta) age=\(info.feedbackDelayMilliseconds)ms owrd=\(info.oneWayReceiveDelay * 1_000, format: .fixed(precision: 3))ms rxLag=\(receiveQueueDelayMilliseconds, format: .fixed(precision: 3))ms"
                )
            }
            performance.recordRateControlFeedback(
                estimatedBandwidthKilobitsPerSecond:
                    info.estimatedBandwidthKilobitsPerSecond
            )
        } catch {
            Self.logger.debug("Rate-control feedback failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func publish(
        _ frame: CVPixelBuffer,
        region: AppleHEVCDecoder.FrameRegion,
        decodingOrderNumber: UInt16?,
        rtpTimestamp: UInt32,
        presentationTime: TimeInterval,
        accessUnitTiming: AppleHEVCAccessUnit.Timing?,
        decodeEnteredAt: TimeInterval,
        decoderSubmittedAt: TimeInterval,
        decoderOutputAt: TimeInterval
    ) {
        let playbackHandledAt = CACurrentMediaTime()
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
            accessUnitTiming: accessUnitTiming,
            decodeEnteredAt: decodeEnteredAt,
            decoderSubmittedAt: decoderSubmittedAt,
            decoderOutputAt: decoderOutputAt,
            playbackHandledAt: playbackHandledAt,
            decodedAt: playbackHandledAt,
            presentationTime: presentationTime
        )
        performance.recordDecodedFrame(rtpTimestamp: rtpTimestamp)
        countLock.withVideoStreamLock {
            self.lastDecodedFrameTime = playbackHandledAt
        }
        let becameReady = countLock.withVideoStreamLock {
            frameCount += 1
            let wasReady = decodedTiles.count == mediaCanvas.tileCount
            if region == .fullCanvas {
                decodedTiles = Set(0..<mediaCanvas.tileCount)
            } else {
                decodedTiles.insert(frameIndex)
            }
            return !wasReady && decodedTiles.count == mediaCanvas.tileCount
        }
        if becameReady {
            publishState(.streaming)
        }
    }

    private func fail(_ error: Error) {
        receiver.stopVideoDelivery(mediaStreamIndex: mediaStreamIndex)
        let timers = lifecycleLock.withVideoStreamLock { () -> (
            DispatchSourceTimer?,
            DispatchSourceTimer?
        )? in
            guard !isClosed else { return nil }
            isClosed = true
            mediaGeneration &+= 1
            let timers = (playbackTimer, rateControlTimer)
            playbackTimer = nil
            rateControlTimer = nil
            return timers
        }
        timers?.0?.cancel()
        timers?.1?.cancel()
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

struct AppleVideoRefreshScheduler {
    private var lastRequestedTimestamp: UInt32?

    mutating func accept(timestamp: UInt32?) -> Bool {
        if let timestamp {
            guard timestamp != lastRequestedTimestamp else { return false }
            lastRequestedTimestamp = timestamp
        }
        return true
    }

    mutating func reset() {
        lastRequestedTimestamp = nil
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
    }

    let keyFrameRequestDelay: TimeInterval
    let keyFrameRequestInterval: TimeInterval
    let recentPacketWindow: TimeInterval

    init(
        keyFrameRequestDelay: TimeInterval = 5,
        keyFrameRequestInterval: TimeInterval = 5,
        recentPacketWindow: TimeInterval = 1.5
    ) {
        self.keyFrameRequestDelay = keyFrameRequestDelay
        self.keyFrameRequestInterval = keyFrameRequestInterval
        self.recentPacketWindow = recentPacketWindow
    }

    func action(
        now: TimeInterval,
        lastDisplayedFrameTime: TimeInterval,
        lastVideoPacketTime: TimeInterval,
        lastKeyFrameRequestTime: TimeInterval
    ) -> Action {
        guard lastDisplayedFrameTime > 0,
              lastVideoPacketTime > 0,
              now - lastVideoPacketTime < recentPacketWindow else { return .none }

        let frameGap = now - lastDisplayedFrameTime
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
