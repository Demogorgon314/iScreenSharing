import Combine
import CoreVideo
import Foundation
import OSLog
import QuartzCore
import struct ScreenSharingProtocol.AppleCanvas

final class AppleVideoStream: SessionVideoStream, @unchecked Sendable {
    typealias DecoderFactory = (
        AppleHEVCParameterSets, Int, AppleVideoDecoderMode
    ) -> AppleHEVCDecodePipeline.DecoderFactory

    private var mediaCanvas: AppleCanvas

    private static let maximumCachedUnitsPerSource = 128
    private static let initialBurstSettleTime: TimeInterval = 0.3
    private static let initialSelectionDeadline: TimeInterval = 2
    private static let minimumInitialPacketCount = 100
    private static let sourceAdoptionStall: TimeInterval = 2
    private static let minimumAdoptionPacketsPerSource = 5
    private static let receiverReportInterval: TimeInterval = 1
    private static let freezeDiagnosticDelay: TimeInterval = 1
    private static let freezeDiagnosticInterval: TimeInterval = 1
    private static let initialRecovery = AppleVideoInitialRecoveryPolicy()
    private static let stallRecovery = AppleVideoStallRecoveryPolicy()
    private static let logger = Logger(subsystem: "com.wangkai.iShareScreen", category: "VideoFeedback")
#if DEBUG && os(iOS)
    private static let debugDiagnosticsQueue = DispatchQueue(
        label: "com.isharescreen.video-stream.diagnostics",
        qos: .utility
    )
#endif

    private let receiver: any AppleMediaReceiving
    private let mediaStreamIndex: Int
    private let processor: AppleHEVCStreamProcessor
    private let feedback: AppleVideoFeedbackController
    private let clock: @Sendable () -> TimeInterval
    private let decoderFactory: DecoderFactory?
    private let rateControlMode: AppleVideoRateControlMode
    private let qualityDiagnosticsEnabled: Bool
    private let freezeDiagnosticsEnabled: Bool
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
    private let receiverReportSourceLock = NSLock()
    private var playbackTimer: DispatchSourceTimer?
    private var rateControlTimer: DispatchSourceTimer?
    private var decodePipeline: AppleHEVCDecodePipeline?
    private var decoderParameterSets: AppleHEVCParameterSets?
    private var hasAttemptedDecoderPreparation = false
    private var decoderMode: AppleVideoDecoderMode
    private var receiverReportSource: UInt32?
    // Playback owns the complete tile mapping. Network feedback reads only
    // the primary-source snapshot, without waiting for playback/decoder work.
    private var sourceToTileStorage = [UInt32: Int]()
    private var sourceToTile: [UInt32: Int] {
        get {
            dispatchPrecondition(condition: .onQueue(queue))
            return sourceToTileStorage
        }
        set {
            dispatchPrecondition(condition: .onQueue(queue))
            sourceToTileStorage = newValue
            let primarySource = newValue.first(where: { $0.value == 0 })?.key
            receiverReportSourceLock.withVideoStreamLock {
                receiverReportSource = primarySource
            }
        }
    }
    private var restartSourceToTile = [UInt32: Int]()
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
    private var lastFreezeDiagnosticTime: TimeInterval = 0
    private var refreshScheduler = AppleVideoRefreshScheduler()
    private var restartSourceSelectionPending = false
#if DEBUG && os(iOS)
    private var debugLastAccessUnitBySource = [UInt32: (
        processingTime: TimeInterval,
        kernelArrivalTime: TimeInterval?
    )]()
    private var debugAccessUnitCount = 0
    private var debugProcessingGapCount = 0
    private var debugKernelArrivalGapCount = 0
    private var debugMaximumProcessingGapMilliseconds = 0.0
    private var debugMaximumKernelArrivalGapMilliseconds = 0.0
    private var debugMaximumIngressAgeMilliseconds = 0.0
    private var debugMaximumSocketBacklogBytes = 0
    private var debugKernelTimestampSampleCount = 0
    private var debugMissingKernelTimestampCount = 0
    private var debugAccessUnitReportStartedAt: TimeInterval?
#endif

    convenience init(
        receiver: any AppleMediaReceiving,
        negotiation: AppleMediaNegotiationResult
    ) throws {
        try self.init(receiver: receiver, video: negotiation.videos[0])
    }

    init(
        receiver: any AppleMediaReceiving,
        video: AppleVideoNegotiation,
        connectionTiming: ConnectionStartupTrace? = nil,
        decoderMode: AppleVideoDecoderMode = .automatic,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        decoderFactory: DecoderFactory? = nil
    ) throws {
        self.receiver = receiver
        self.decoderMode = decoderMode
        self.clock = clock
        self.decoderFactory = decoderFactory
        mediaStreamIndex = video.mediaStreamIndex
        mediaCanvas = video.canvas
        processor = try AppleHEVCStreamProcessor(keyBlob: video.serverKey)
        let environment = ProcessInfo.processInfo.environment
        rateControlMode = AppleVideoRateControlMode(
            environmentValue: environment["ISHARESCREEN_RCTL_MODE"]
        )
        qualityDiagnosticsEnabled = environment["ISHARESCREEN_QUALITY_DIAGNOSTICS"] == "1"
        freezeDiagnosticsEnabled = environment["ISHARESCREEN_FREEZE_DIAGNOSTICS"] == "1"
        feedback = try AppleVideoFeedbackController(
            sender: AppleVideoFeedbackSender(receiver: receiver, mediaStreamIndex: video.mediaStreamIndex),
            keyBlob: video.viewerKey,
            synchronizationSource: video.synchronizationSource
        )
        let frames: AppleVideoFrameStore
#if os(iOS)
        frames = AppleVideoFrameStore(
            preservesLogicalFrameBatches: true,
            logicalFrameQueueCapacity: 2,
            deliversLogicalFrameBatchesOnDemand: true
        )
#else
        frames = AppleVideoFrameStore()
#endif
        super.init(
            canvas: video.canvas,
            displayIndex: video.displayIndex,
            tileCount: video.canvas.tileCount,
            connectionTiming: connectionTiming,
            frames: frames
        )
        performance.setSocketReceiveBufferBytes(
            receiver.videoReceiveBufferConfiguration(
                mediaStreamIndex: video.mediaStreamIndex
            )?.actualBytes
        )
    }

    override var decodedFrameCount: Int {
        countLock.withVideoStreamLock { frameCount }
    }

    override func setDecoderMode(_ mode: AppleVideoDecoderMode) {
        queue.async { [weak self] in
            guard let self else { return }
            let isOpen = self.lifecycleLock.withVideoStreamLock { !self.isClosed }
            guard isOpen, mode != self.decoderMode else { return }
            self.decoderMode = mode
            guard let decodePipeline = self.decodePipeline,
                  let parameterSets = self.decoderParameterSets else { return }
            if !decodePipeline.isActive {
                decodePipeline.close()
                self.decodePipeline = nil
                self.decoderParameterSets = nil
                return
            }
            do {
                decodePipeline.setSynchronizesVideoToolboxTiles(
                    mode.synchronizesVideoToolboxTiles
                )
                try decodePipeline.replaceDecoder(using: self.makeDecoderFactory(
                    parameterSets: parameterSets,
                    tileCount: self.mediaCanvas.tileCount,
                    decoderMode: mode,
                    performanceMonitor: self.performance
                ))
                self.scheduleKeyFramesForAllTiles()
            } catch {
                self.fail(error)
            }
        }
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
                if let pipeline = self.decodePipeline,
                   !pipeline.isActive, pipeline.tileCount != canvas.tileCount {
                    pipeline.close()
                    self.decodePipeline = nil
                    self.decoderParameterSets = nil
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

                self.restartSourceToTile = self.sourceToTile
                self.sourceToTile.removeAll(keepingCapacity: false)
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
                self.hasAttemptedDecoderPreparation = false
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
                self.lastFreezeDiagnosticTime = 0
                self.playbackWatchdogStartTime = 0
                self.refreshScheduler.reset()
                self.restartSourceSelectionPending = true
                continuation.resume()
            }
        }
    }

    override func start() {
        connectionTiming?.record(.videoStarted, index: displayIndex)
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

    override func close() {
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
        guard lifecycleLock.withVideoStreamLock({ !isClosed }) else { return }
        processor.expireIncompleteAccessUnits(at: clock())
        if decodePipeline?.isActive != true {
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
        let processingTime = clock()
        countLock.withVideoStreamLock {
            self.lastVideoPacketTime = processingTime
            self.latestReceiveQueueDelayMilliseconds = max(
                0,
                (processingTime - datagram.arrivalTime) * 1_000
            )
            if self.firstPacketTime == nil {
                self.firstPacketTime = processingTime
                connectionTiming?.record(
                    .firstPacket, index: displayIndex,
                    since: .init(.videoStarted, index: displayIndex)
                )
            }
        }
        performance.recordNetwork(
            packetCount: 1,
            byteCount: datagram.data.count,
            estimatedSocketBacklogBytes: datagram.estimatedSocketBacklogBytes,
            receiveDrainDuration: processingTime - datagram.receiveBatchStartedAt,
            ingressAge: datagram.ingressAge,
            receiveBufferOverflowCount: datagram.receiveBufferOverflowCount,
            networkPath: datagram.networkPath
        )
        let accessUnit = processor.process(datagram)
        sendReceiverReportIfNeeded()
        sendPendingNACKs()
        sendFrameLossFeedbackIfNeeded()
        guard let accessUnit else { return }
#if DEBUG && os(iOS)
        debugAccessUnitCount += 1
        debugMaximumSocketBacklogBytes = max(
            debugMaximumSocketBacklogBytes,
            datagram.estimatedSocketBacklogBytes
        )
        let kernelArrivalTime = datagram.kernelArrivalTime
        if kernelArrivalTime == nil {
            debugMissingKernelTimestampCount += 1
        } else {
            debugKernelTimestampSampleCount += 1
        }
        if let previous = debugLastAccessUnitBySource[accessUnit.synchronizationSource] {
            let processingGapMilliseconds = (processingTime - previous.processingTime) * 1_000
            if processingGapMilliseconds > 40 {
                debugProcessingGapCount += 1
                debugMaximumProcessingGapMilliseconds = max(
                    debugMaximumProcessingGapMilliseconds,
                    processingGapMilliseconds
                )
            }
            if let kernelArrivalTime, let previousKernelArrivalTime = previous.kernelArrivalTime {
                let kernelGapMilliseconds = (kernelArrivalTime - previousKernelArrivalTime) * 1_000
                if kernelGapMilliseconds > 40 {
                    debugKernelArrivalGapCount += 1
                    debugMaximumKernelArrivalGapMilliseconds = max(
                        debugMaximumKernelArrivalGapMilliseconds,
                        kernelGapMilliseconds
                    )
                }
            }
        }
        debugMaximumIngressAgeMilliseconds = max(
            debugMaximumIngressAgeMilliseconds,
            datagram.ingressAge.map { $0 * 1_000 } ?? 0
        )
        debugLastAccessUnitBySource[accessUnit.synchronizationSource] = (
            processingTime,
            kernelArrivalTime
        )
        let reportStartedAt = debugAccessUnitReportStartedAt ?? processingTime
        debugAccessUnitReportStartedAt = reportStartedAt
        if processingTime - reportStartedAt >= 1 {
            let diagnostic = "[DEBUG-IOS-AU-CADENCE-4F83] units=\(debugAccessUnitCount) processGaps=\(debugProcessingGapCount)/\(Int(debugMaximumProcessingGapMilliseconds.rounded()))ms kernelGaps=\(debugKernelArrivalGapCount)/\(Int(debugMaximumKernelArrivalGapMilliseconds.rounded()))ms kernelSamples=\(debugKernelTimestampSampleCount) missing=\(debugMissingKernelTimestampCount) ingressMax=\(Int(debugMaximumIngressAgeMilliseconds.rounded()))ms backlog=\(debugMaximumSocketBacklogBytes)"
            Self.debugDiagnosticsQueue.async { print(diagnostic) }
            debugAccessUnitCount = 0
            debugProcessingGapCount = 0
            debugKernelArrivalGapCount = 0
            debugMaximumProcessingGapMilliseconds = 0
            debugMaximumKernelArrivalGapMilliseconds = 0
            debugMaximumIngressAgeMilliseconds = 0
            debugMaximumSocketBacklogBytes = 0
            debugKernelTimestampSampleCount = 0
            debugMissingKernelTimestampCount = 0
            debugAccessUnitReportStartedAt = processingTime
        }
#endif
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
        performance.recordReceivedFrame(rtpTimestamp: accessUnit.timestamp)
        if decodePipeline?.isActive != true { prepareDecoderIfPossible() }
        if decodePipeline?.isActive == true {
            replaceDecoderForChangedParameterSetsIfNeeded()
        }

        if decodePipeline?.isActive != true || sourceToTile.count != mediaCanvas.tileCount {
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
        guard lifecycleLock.withVideoStreamLock({ !isClosed }) else { return }
        guard let firstPacketTime = countLock.withVideoStreamLock({ self.firstPacketTime }) else {
            return
        }
        let hasCompleteParameterSets = processor.currentParameterSets().isComplete
        if hasCompleteParameterSets {
            connectionTiming?.record(
                .parameterSetsReady, index: displayIndex,
                since: .init(.firstPacket, index: displayIndex)
            )
        }
        if hasCompleteParameterSets,
           let sources = AppleVideoWarmRestartSourcePolicy.sources(
               previousSourceToTile: restartSourceToTile,
               observedSources: Set(cachedUnits.keys),
               tileCount: mediaCanvas.tileCount
           ) {
            sourceToTile = restartSourceToTile
            restartSourceToTile.removeAll(keepingCapacity: false)
            restartSourceSelectionPending = false
            prepareDecoder(for: sources)
            return
        }
        if let sources = freshRestartSourcesIfReady() {
            sourceToTile = Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($1, $0) })
            restartSourceToTile.removeAll(keepingCapacity: false)
            restartSourceSelectionPending = false
            prepareDecoder(for: sources)
            return
        }
        let now = clock()
        if initialBurstReadyTime == nil,
           (processor.totalPacketCount >= Self.minimumInitialPacketCount
            || now - firstPacketTime >= Self.initialSelectionDeadline) {
            initialBurstReadyTime = now
            initialPacketCountBaseline = processor.packetCounts
            connectionTiming?.record(
                .selectionThreshold, index: displayIndex,
                since: .init(.firstPacket, index: displayIndex),
                count: processor.totalPacketCount
            )
        }
        guard let initialBurstReadyTime else { return }
        if now - initialBurstReadyTime < Self.initialBurstSettleTime {
            // Capture the selection baseline and start its clock before doing
            // decoder work, so preparation overlaps the observation window.
            if hasCompleteParameterSets, !hasAttemptedDecoderPreparation {
                hasAttemptedDecoderPreparation = true
                connectionTiming?.record(
                    .decoderPreparationStarted, index: displayIndex,
                    since: .init(.selectionThreshold, index: displayIndex)
                )
                do {
                    try createDecodePipelineIfPossible()
                    connectionTiming?.record(
                        .decoderPreparationReady, index: displayIndex,
                        since: .init(.decoderPreparationStarted, index: displayIndex)
                    )
                } catch {
                    // Speculative parameters may be superseded before selection.
                    // Retry once on the normal activation path, with its error policy.
                    connectionTiming?.record(
                        .decoderPreparationFailed, index: displayIndex,
                        since: .init(.decoderPreparationStarted, index: displayIndex)
                    )
                }
            }
            return
        }
        let sources = processor.primarySources(
            tileCount: mediaCanvas.tileCount,
            packetCountBaseline: initialPacketCountBaseline
        )
        guard sources.count == mediaCanvas.tileCount else { return }
        sourceToTile = Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($1, $0) })
        restartSourceToTile.removeAll(keepingCapacity: false)
        restartSourceSelectionPending = false
        recoverMissingInitialParameterSetsIfNeeded(now: now)
        prepareDecoder(for: sources)
    }

    private func freshRestartSourcesIfReady() -> [UInt32]? {
        guard restartSourceSelectionPending else { return nil }
        return AppleVideoFreshRestartSourcePolicy.sources(
            currentSources: processor.primarySources(tileCount: mediaCanvas.tileCount),
            completedAccessUnitSources: Set(cachedUnits.keys),
            tileCount: mediaCanvas.tileCount,
            hasCompleteParameterSets: processor.currentParameterSets().isComplete
        )
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
        guard decodePipeline?.isActive != true else { return }
        connectionTiming?.record(
            .sourcesSelected, index: displayIndex,
            since: .init(.selectionThreshold, index: displayIndex)
        )

        guard processor.currentParameterSets().isComplete else { return }
        connectionTiming?.record(
            .decoderStarted, index: displayIndex,
            since: .init(.sourcesSelected, index: displayIndex)
        )
        do {
            let hadPreparedDecoder = decodePipeline != nil
            try createDecodePipelineIfPossible()
            let replacedDecoder = replaceDecoderForChangedParameterSetsIfNeeded()
            guard lifecycleLock.withVideoStreamLock({ !isClosed }),
                  let decodePipeline,
                  decodePipeline.activate(sourceToTile: sourceToTile) else { return }
            if hadPreparedDecoder, !replacedDecoder {
                connectionTiming?.record(
                    .decoderPreparationReused, index: displayIndex,
                    since: .init(.decoderPreparationReady, index: displayIndex)
                )
            }
            connectionTiming?.record(
                .decoderReady, index: displayIndex,
                since: .init(.decoderStarted, index: displayIndex)
            )
            countLock.withVideoStreamLock {
                self.lastDecodedFrameTime = clock()
            }
            playbackWatchdogStartTime = clock()
            feedCachedUnitsInDecodingOrder(sources: sources)
        } catch {
            fail(error)
        }
    }

    private func createDecodePipelineIfPossible() throws {
        guard decodePipeline == nil else { return }
        let parameterSets = processor.currentParameterSets()
        guard parameterSets.isComplete else { return }
        let tileCount = mediaCanvas.tileCount
        let performanceMonitor = performance
        decodePipeline = try AppleHEVCDecodePipeline(
            tileCount: tileCount,
            callbackQueue: queue,
            decoderFactory: makeDecoderFactory(
                parameterSets: parameterSets,
                tileCount: tileCount,
                decoderMode: decoderMode,
                performanceMonitor: performanceMonitor
            ),
            outputHandler: { [weak self] decodedFrames in
                self?.publish(decodedFrames)
            },
            synchronizesVideoToolboxTiles:
                decoderMode.synchronizesVideoToolboxTiles,
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
            refreshHandler: { [weak self] request in
                self?.scheduleKeyFramesForAllTiles(
                    timestamp: request.timestamp,
                    discardsBufferedAccessUnits: request.startsRefreshState
                )
            },
            errorHandler: { [weak self] error in self?.fail(error) }
        )
        decoderParameterSets = parameterSets
    }

    private func adoptFreshSourcesIfNeeded() {
        let now = clock()
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
        let now = clock()
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
        logDecoderStallIfNeeded(
            now: now,
            lastDisplayedFrameTime: lastDisplayedFrameTime,
            lastVideoPacketTime: lastVideoPacketTime,
            recoveryAction: action
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

    private func logDecoderStallIfNeeded(
        now: TimeInterval,
        lastDisplayedFrameTime: TimeInterval,
        lastVideoPacketTime: TimeInterval,
        recoveryAction: AppleVideoStallRecoveryPolicy.Action
    ) {
        guard freezeDiagnosticsEnabled else { return }
        let displayAge = now - lastDisplayedFrameTime
        let packetAge = now - lastVideoPacketTime
        guard displayAge >= Self.freezeDiagnosticDelay,
              packetAge < Self.stallRecovery.recentPacketWindow else {
            lastFreezeDiagnosticTime = 0
            return
        }
        guard lastFreezeDiagnosticTime == 0
                || now - lastFreezeDiagnosticTime >= Self.freezeDiagnosticInterval,
              let diagnostics = decodePipeline?.diagnostics() else { return }
        lastFreezeDiagnosticTime = now

        let backend = diagnostics.decoderBackend?.rawValue ?? "none"
        let action = recoveryAction == .requestKeyFrames ? "requestFIR" : "observe"
        let selectedAge = Self.diagnosticAge(
            now: now,
            since: diagnostics.lastSelectedAccessUnitAt
        )
        let attemptAge = Self.diagnosticAge(
            now: now,
            since: diagnostics.lastDecodeAttemptAt
        )
        let callbackAge = Self.diagnosticAge(
            now: now,
            since: diagnostics.lastDecoderCallbackAt
        )
        let synchronization = diagnostics.tileSynchronization
        let oldestFrame = synchronization.oldestFrameSequenceNumber.map(String.init) ?? "none"

        Self.logger.notice(
            "[DEBUG-VTSTALL-91C7] gen=\(diagnostics.decoderGeneration) backend=\(backend, privacy: .public) action=\(action, privacy: .public) age display=\(displayAge * 1_000, format: .fixed(precision: 1))ms packet=\(packetAge * 1_000, format: .fixed(precision: 1))ms selected=\(selectedAge, privacy: .public) attempt=\(attemptAge, privacy: .public) callback=\(callbackAge, privacy: .public) admission=\(diagnostics.selectedAccessUnitCount)/\(diagnostics.admittedAccessUnitCount)/\(diagnostics.videoSliceCount) decode=\(diagnostics.acceptedDecodeCount)/\(diagnostics.rejectedDecodeCount)/\(diagnostics.decoderCallbackCount)/\(diagnostics.decoderFailureCount) outstanding=\(diagnostics.outstandingDecodeCount)/\(diagnostics.maximumOutstandingDecodeCount) sync groups=\(synchronization.pendingGroupCount) oldest=\(oldestFrame, privacy: .public) closed=\(synchronization.oldestGroupIsClosed) tiles=\(synchronization.oldestDecodedTileCount)/\(synchronization.oldestSubmittedTileCount)"
        )
    }

    private static func diagnosticAge(
        now: TimeInterval,
        since timestamp: TimeInterval?
    ) -> String {
        guard let timestamp else { return "none" }
        return String(format: "%.1fms", max(0, now - timestamp) * 1_000)
    }

    @discardableResult
    private func replaceDecoderForChangedParameterSetsIfNeeded() -> Bool {
        guard let decodePipeline,
              let decoderParameterSets,
              AppleHEVCDecoder.requiresReplacement(
                  configured: decoderParameterSets,
                  current: processor.currentParameterSets()
              ) else { return false }
        let parameterSets = processor.currentParameterSets()
        do {
            try decodePipeline.replaceDecoder(using: makeDecoderFactory(
                parameterSets: parameterSets,
                tileCount: mediaCanvas.tileCount,
                decoderMode: decoderMode,
                performanceMonitor: performance
            ))
            self.decoderParameterSets = parameterSets
            return true
        } catch {
            fail(error)
            return false
        }
    }

    private func makeDecoderFactory(
        parameterSets: AppleHEVCParameterSets,
        tileCount: Int,
        decoderMode: AppleVideoDecoderMode,
        performanceMonitor: AppleVideoPerformanceMonitor
    ) -> AppleHEVCDecodePipeline.DecoderFactory {
        if let decoderFactory {
            return decoderFactory(parameterSets, tileCount, decoderMode)
        }
        let timing = connectionTiming
        let displayIndex = displayIndex
        return { failureHandler, frameHandler, longTermReferenceHandler in
            try AppleHEVCDecoder(
                parameterSets: parameterSets,
                tileCount: tileCount,
                decoderMode: decoderMode,
                backendHandler: { backend in
                    performanceMonitor.setDecoderBackend(backend)
                },
                failureHandler: failureHandler,
                longTermReferenceHandler: longTermReferenceHandler,
                frameHandler: { frame in
                    timing?.record(
                        .firstDecoded, index: displayIndex,
                        since: .init(.decoderReady, index: displayIndex),
                        at: frame.decoderOutputAt
                    )
                    frameHandler(frame)
                }
            )
        }
    }

    private func scheduleKeyFramesForAllTiles(
        timestamp: UInt32? = nil,
        discardsBufferedAccessUnits: Bool = true
    ) {
        if discardsBufferedAccessUnits {
            processor.discardBufferedAccessUnits()
            cachedUnits.removeAll(keepingCapacity: false)
        }
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
        let currentTime = clock()
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
        let currentTime = clock()
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
        let currentTime = clock()
        guard currentTime - lastReceiverReportTime >= Self.receiverReportInterval else { return }
        do {
            let source = receiverReportSourceLock.withVideoStreamLock { receiverReportSource }
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
        let currentTime = clock()
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

    private func publish(_ decodedFrames: [AppleHEVCDecoder.DecodedFrame]) {
        guard !decodedFrames.isEmpty else { return }
        let playbackHandledAt = CACurrentMediaTime()
        connectionTiming?.record(
            .firstFramePublished, index: displayIndex,
            since: .init(.firstDecoded, index: displayIndex), at: playbackHandledAt
        )
        for decodedFrame in decodedFrames {
            performance.recordDecode(duration: decodedFrame.decodeDuration)
            if let timing = decodedFrame.accessUnitTiming {
                performance.recordAccessUnitToDecoderOutput(
                    duration: decodedFrame.decoderOutputAt - timing.assemblyCompletedAt
                )
            }
            performance.recordDecodedFrame(rtpTimestamp: decodedFrame.rtpTimestamp)
        }
        frames.publish(
            decodedFrames,
            playbackHandledAt: playbackHandledAt
        )
        countLock.withVideoStreamLock {
            self.lastDecodedFrameTime = playbackHandledAt
        }
        let becameReady = countLock.withVideoStreamLock {
            frameCount += decodedFrames.count
            let wasReady = decodedTiles.count == mediaCanvas.tileCount
            for decodedFrame in decodedFrames {
                switch decodedFrame.region {
                case let .tile(tileIndex):
                    decodedTiles.insert(tileIndex)
                case .fullCanvas:
                    decodedTiles = Set(0..<mediaCanvas.tileCount)
                }
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
    private let receiver: any AppleMediaReceiving
    private let mediaStreamIndex: Int

    init(receiver: any AppleMediaReceiving, mediaStreamIndex: Int) {
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

struct AppleVideoWarmRestartSourcePolicy {
    static func sources(
        previousSourceToTile: [UInt32: Int],
        observedSources: Set<UInt32>,
        tileCount: Int
    ) -> [UInt32]? {
        guard tileCount > 0,
              previousSourceToTile.count == tileCount,
              observedSources.isSuperset(of: previousSourceToTile.keys) else { return nil }

        var sources = [UInt32?](repeating: nil, count: tileCount)
        for (source, tileIndex) in previousSourceToTile {
            guard sources.indices.contains(tileIndex), sources[tileIndex] == nil else { return nil }
            sources[tileIndex] = source
        }
        guard sources.allSatisfy({ $0 != nil }) else { return nil }
        return sources.compactMap { $0 }
    }
}

struct AppleVideoFreshRestartSourcePolicy {
    static func sources(
        currentSources: [UInt32],
        completedAccessUnitSources: Set<UInt32>,
        tileCount: Int,
        hasCompleteParameterSets: Bool
    ) -> [UInt32]? {
        guard hasCompleteParameterSets,
              tileCount > 0,
              currentSources.count == tileCount,
              Set(currentSources).count == tileCount,
              completedAccessUnitSources.isSuperset(of: currentSources) else { return nil }
        return currentSources
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
    func startVideo(
        for session: RFBAuthenticatedSession,
        negotiation: AppleMediaNegotiationResult,
        decoderMode: AppleVideoDecoderMode
    ) throws
}

struct AppleVideoStreamStarter: AppleVideoStreamStarting {
    func startVideo(
        for session: RFBAuthenticatedSession,
        negotiation: AppleMediaNegotiationResult,
        decoderMode: AppleVideoDecoderMode
    ) throws {
        guard let receiver = session.mediaReceiver else {
            throw AppleVideoStreamError.missingMediaReceiver
        }
        let streams: [SessionVideoStream] = try negotiation.videos.map {
            try AppleVideoStream(
                receiver: receiver, video: $0, connectionTiming: session.connectionTiming,
                decoderMode: decoderMode
            )
        }
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
