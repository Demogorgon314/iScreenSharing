import Foundation
import OSLog
import QuartzCore
import VideoToolbox

protocol AppleHEVCDecodeSubmitting: AnyObject {
    var backend: AppleHEVCDecoder.Backend { get }

    @discardableResult
    func decode(
        _ nalUnits: [Data],
        tileIndex: Int,
        decodingOrderNumber: UInt16?,
        isLongTermReferenceFrame: Bool,
        rtpTimestamp: UInt32,
        presentationTime: TimeInterval,
        timing: AppleHEVCAccessUnit.Timing?
    ) throws -> Bool

    func close()
}

extension AppleHEVCDecoder: AppleHEVCDecodeSubmitting {}

/// Owns DON admission, playout time, and a stable decoder session for one
/// negotiated high-performance video stream.
final class AppleHEVCDecodePipeline: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "com.wangkai.iShareScreen",
        category: "VideoPipeline"
    )

    typealias DecoderFactory = (
        @escaping AppleHEVCDecoder.FailureHandler,
        @escaping AppleHEVCDecoder.FrameHandler,
        @escaping AppleHEVCDecoder.LongTermReferenceHandler
    ) throws -> any AppleHEVCDecodeSubmitting

    typealias OutputHandler = @Sendable ([AppleHEVCDecoder.DecodedFrame]) -> Void
    typealias LongTermReferenceHandler = @Sendable (UInt16) -> Void
    typealias RefreshHandler = @Sendable (UInt32) -> Void
    typealias ErrorHandler = @Sendable (Error) -> Void

    private final class CallbackBridge: @unchecked Sendable {
        typealias Generation = UInt64

        private let lock = NSLock()
        private var frameHandler: ((Generation, AppleHEVCDecoder.DecodedFrame) -> Void)?
        private var failureHandler: ((Generation, AppleHEVCDecoder.DecodeFailure) -> Void)?
        private var longTermReferenceHandler: ((Generation, UInt16) -> Void)?

        func install(
            frameHandler: @escaping (Generation, AppleHEVCDecoder.DecodedFrame) -> Void,
            failureHandler: @escaping (Generation, AppleHEVCDecoder.DecodeFailure) -> Void,
            longTermReferenceHandler: @escaping (Generation, UInt16) -> Void
        ) {
            lock.lock()
            self.frameHandler = frameHandler
            self.failureHandler = failureHandler
            self.longTermReferenceHandler = longTermReferenceHandler
            lock.unlock()
        }

        func emit(_ frame: AppleHEVCDecoder.DecodedFrame, generation: Generation) {
            let handler = locked { frameHandler }
            handler?(generation, frame)
        }

        func emit(_ failure: AppleHEVCDecoder.DecodeFailure, generation: Generation) {
            let handler = locked { failureHandler }
            handler?(generation, failure)
        }

        func emitLongTermReference(
            _ decodingOrderNumber: UInt16,
            generation: Generation
        ) {
            let handler = locked { longTermReferenceHandler }
            handler?(generation, decodingOrderNumber)
        }

        func clear() {
            lock.lock()
            frameHandler = nil
            failureHandler = nil
            longTermReferenceHandler = nil
            lock.unlock()
        }

        private func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    private let sourceToTile: [UInt32: Int]
    private let callbackQueue: DispatchQueue
    private let outputHandler: OutputHandler
    private let longTermReferenceHandler: LongTermReferenceHandler
    private let refreshHandler: RefreshHandler
    private let errorHandler: ErrorHandler
    private let callbackBridge: CallbackBridge
    private var synchronizesVideoToolboxTiles: Bool
    private var tileFrameSynchronizer: AppleVideoTileFrameSynchronizer?
    private var decoder: (any AppleHEVCDecodeSubmitting)?
    private var admission = AppleHEVCDecodingOrderQueue()
    private var playoutClock = AppleVideoPlayoutClock()
    private var lastRefreshRequestTimestamp: UInt32?
    private var tilesAwaitingRefresh = Set<Int>()
    private var decoderGeneration: UInt64 = 0
    private var isClosed = false
    private let freezeDiagnosticsEnabled = ProcessInfo.processInfo.environment[
        "ISHARESCREEN_FREEZE_DIAGNOSTICS"
    ] == "1"

    init(
        tileCount: Int,
        sourceToTile: [UInt32: Int],
        callbackQueue: DispatchQueue,
        decoderFactory: DecoderFactory,
        outputHandler: @escaping OutputHandler,
        synchronizesVideoToolboxTiles: Bool = false,
        longTermReferenceHandler: @escaping LongTermReferenceHandler = { _ in },
        refreshHandler: @escaping RefreshHandler,
        errorHandler: @escaping ErrorHandler
    ) throws {
        precondition(tileCount > 0)
        precondition(sourceToTile.count == tileCount)
        self.sourceToTile = sourceToTile
        self.callbackQueue = callbackQueue
        self.outputHandler = outputHandler
        self.longTermReferenceHandler = longTermReferenceHandler
        self.refreshHandler = refreshHandler
        self.errorHandler = errorHandler
        callbackBridge = CallbackBridge()
        self.synchronizesVideoToolboxTiles = synchronizesVideoToolboxTiles
        tileFrameSynchronizer = nil
        decoder = nil

        decoder = try makeDecoder(using: decoderFactory)
        updateTileFrameSynchronizer()
        callbackBridge.install(
            frameHandler: { [weak self, callbackQueue] generation, frame in
                callbackQueue.async { [weak self] in
                    self?.handleDecodedFrame(frame, generation: generation)
                }
            },
            failureHandler: { [weak self, callbackQueue] generation, failure in
                callbackQueue.async { [weak self] in
                    self?.handleDecodeFailure(failure, generation: generation)
                }
            },
            longTermReferenceHandler: {
                [weak self, callbackQueue] generation, decodingOrderNumber in
                callbackQueue.async { [weak self] in
                    self?.handleLongTermReference(
                        decodingOrderNumber,
                        generation: generation
                    )
                }
            }
        )
    }

    func submit(_ accessUnits: [AppleHEVCAccessUnit]) {
        guard !isClosed else { return }
        let selectedUnits = accessUnits.filter {
            sourceToTile[$0.synchronizationSource] != nil
        }
        let output = admission.enqueue(selectedUnits)

        for accessUnit in output.accessUnits {
            guard let tileIndex = sourceToTile[accessUnit.synchronizationSource],
                  accessUnit.nalUnits.contains(where: Self.isVideoSlice) else { continue }
            let presentationTime = playoutClock.presentationTime(
                for: accessUnit.timestamp,
                hostTime: CACurrentMediaTime()
            )
            do {
                let shouldFlush = tileFrameSynchronizer?.recordSubmission(
                    frameSequenceNumber:
                        accessUnit.timing?.observedFrameSequenceNumber,
                    tileIndex: tileIndex,
                    subframeBoundary: accessUnit.subframeBoundary
                ) == true
                if shouldFlush { scheduleSynchronizedFlush(generation: decoderGeneration) }
                _ = try decoder?.decode(
                    accessUnit.nalUnits,
                    tileIndex: tileIndex,
                    decodingOrderNumber: accessUnit.decodingOrderNumber,
                    isLongTermReferenceFrame: accessUnit.isLongTermReferenceFrame,
                    rtpTimestamp: accessUnit.timestamp,
                    presentationTime: presentationTime,
                    timing: accessUnit.timing
                )
            } catch let AppleHEVCDecoderError.decodeFailed(status) {
                let shouldFlush = tileFrameSynchronizer?.recordDecodeFailure(
                    frameSequenceNumber:
                        accessUnit.timing?.observedFrameSequenceNumber,
                    tileIndex: tileIndex
                ) == true
                if shouldFlush { scheduleSynchronizedFlush(generation: decoderGeneration) }
                var shouldLog = true
                if status == kVTVideoDecoderReferenceMissingErr {
                    shouldLog = beginRefreshRecoveryIfNeeded(
                        forTile: tileIndex,
                        timestamp: accessUnit.timestamp
                    )
                }
                if shouldLog {
                    logFreezeDiagnostic(
                        "synchronous status=\(status) rtp=\(accessUnit.timestamp); continuing submissions"
                    )
                    Self.logger.notice(
                        "Synchronous video decode failure status=\(status, privacy: .public); continuing submissions"
                    )
                }
            } catch {
                errorHandler(error)
                break
            }
        }
    }

    /// Mirrors AVConference's no-video watchdog: reset only DON admission.
    /// Decoder identity and playout anchoring remain stable.
    func resetDecodingOrder() {
        guard !isClosed else { return }
        admission.reset()
    }

    /// Changes only the public VideoToolbox presentation policy. The decoder
    /// session and playout clock remain stable across a menu-driven mode change.
    func setSynchronizesVideoToolboxTiles(_ enabled: Bool) {
        guard !isClosed else { return }
        synchronizesVideoToolboxTiles = enabled
        updateTileFrameSynchronizer()
    }

    /// Replaces only the decompression session for a new video format. RTP
    /// admission and playout anchoring remain continuous across the change.
    func replaceDecoder(using decoderFactory: DecoderFactory) throws {
        guard !isClosed else { throw AppleHEVCDecoderError.sessionClosed }
        decoder?.close()
        decoder = nil
        tileFrameSynchronizer?.reset()
        tilesAwaitingRefresh.removeAll(keepingCapacity: true)
        decoder = try makeDecoder(using: decoderFactory)
        updateTileFrameSynchronizer()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        callbackBridge.clear()
        tileFrameSynchronizer?.reset()
        decoder?.close()
        decoder = nil
    }

    deinit {
        close()
    }

    private func handleDecodeFailure(
        _ failure: AppleHEVCDecoder.DecodeFailure,
        generation: UInt64
    ) {
        guard !isClosed, generation == decoderGeneration else { return }
        let shouldFlush = tileFrameSynchronizer?.recordDecodeFailure(
            frameSequenceNumber: failure.frameSequenceNumber,
            tileIndex: failure.tileIndex
        ) == true
        if shouldFlush { scheduleSynchronizedFlush(generation: generation) }
        logFreezeDiagnostic(
            "asynchronous reason=\(failure.reason.rawValue) status=\(failure.status) rtp=\(failure.rtpTimestamp); continuing submissions"
        )
        guard failure.reason == .decoderStatus else { return }
        var shouldLog = true
        if failure.status == kVTVideoDecoderReferenceMissingErr {
            shouldLog = beginRefreshRecoveryIfNeeded(
                forTile: failure.tileIndex,
                timestamp: failure.rtpTimestamp
            )
        }
        if shouldLog {
            Self.logger.notice(
                "Asynchronous video decode failure tile=\(failure.tileIndex, privacy: .public) reason=\(failure.reason.rawValue, privacy: .public) status=\(failure.status, privacy: .public); continuing submissions"
            )
        }
    }

    private func makeDecoder(using decoderFactory: DecoderFactory) throws
        -> any AppleHEVCDecodeSubmitting {
        decoderGeneration &+= 1
        let generation = decoderGeneration
        return try decoderFactory(
            { [callbackBridge] failure in
                callbackBridge.emit(failure, generation: generation)
            },
            { [callbackBridge] frame in
                callbackBridge.emit(frame, generation: generation)
            },
            { [callbackBridge] decodingOrderNumber in
                callbackBridge.emitLongTermReference(
                    decodingOrderNumber,
                    generation: generation
                )
            }
        )
    }

    private func updateTileFrameSynchronizer() {
        let shouldSynchronize = synchronizesVideoToolboxTiles
            && decoder?.backend == .videoToolbox
        guard shouldSynchronize != (tileFrameSynchronizer != nil) else { return }
        tileFrameSynchronizer?.reset()
        tileFrameSynchronizer = shouldSynchronize
            ? AppleVideoTileFrameSynchronizer()
            : nil
    }

    private func handleDecodedFrame(
        _ frame: AppleHEVCDecoder.DecodedFrame,
        generation: UInt64
    ) {
        guard !isClosed, generation == decoderGeneration else { return }
        switch frame.region {
        case let .tile(tileIndex):
            tilesAwaitingRefresh.remove(tileIndex)
        case .fullCanvas:
            tilesAwaitingRefresh.removeAll(keepingCapacity: true)
        }
        guard let tileFrameSynchronizer else {
            outputHandler([frame])
            return
        }
        guard case .tile = frame.region,
              frame.accessUnitTiming?.observedFrameSequenceNumber != nil else {
            outputHandler([frame])
            return
        }
        if tileFrameSynchronizer.recordDecodedFrame(frame) {
            scheduleSynchronizedFlush(generation: generation)
        }
    }

    private func scheduleSynchronizedFlush(generation: UInt64) {
        callbackQueue.async { [weak self] in
            self?.flushSynchronizedFrames(generation: generation)
        }
    }

    private func flushSynchronizedFrames(generation: UInt64) {
        guard !isClosed, generation == decoderGeneration,
              let tileFrameSynchronizer else { return }
        for batch in tileFrameSynchronizer.drainReadyBatches() {
            outputHandler(batch)
        }
    }

    private func handleLongTermReference(
        _ decodingOrderNumber: UInt16,
        generation: UInt64
    ) {
        guard !isClosed, generation == decoderGeneration else { return }
        longTermReferenceHandler(decodingOrderNumber)
    }

    @discardableResult
    private func beginRefreshRecoveryIfNeeded(
        forTile tileIndex: Int,
        timestamp: UInt32
    ) -> Bool {
        let wasRecovering = !tilesAwaitingRefresh.isEmpty
        tilesAwaitingRefresh.insert(tileIndex)
        guard !wasRecovering else { return false }
        if timestamp != lastRefreshRequestTimestamp {
            lastRefreshRequestTimestamp = timestamp
            refreshHandler(timestamp)
        }
        return true
    }

    private func logFreezeDiagnostic(_ message: String) {
        guard freezeDiagnosticsEnabled else { return }
        Self.logger.notice("[DEBUG-FREEZE-2F6D] \(message, privacy: .public)")
    }

    private static func isVideoSlice(_ nalUnit: Data) -> Bool {
        guard let type = AppleHEVCNALUnit.type(of: nalUnit) else { return false }
        return type < 32
    }
}
