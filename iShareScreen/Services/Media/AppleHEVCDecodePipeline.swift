import Foundation
import OSLog
import QuartzCore
import VideoToolbox

protocol AppleHEVCDecodeSubmitting: AnyObject {
    @discardableResult
    func decode(
        _ nalUnits: [Data],
        tileIndex: Int,
        decodingOrderNumber: UInt16?,
        rtpTimestamp: UInt32,
        presentationTime: TimeInterval
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
        @escaping AppleHEVCDecoder.FrameHandler
    ) throws -> any AppleHEVCDecodeSubmitting

    typealias FrameHandler = @Sendable (AppleHEVCDecoder.DecodedFrame) -> Void
    typealias RefreshHandler = @Sendable (UInt32) -> Void
    typealias ErrorHandler = @Sendable (Error) -> Void

    private final class CallbackBridge: @unchecked Sendable {
        private let lock = NSLock()
        private var frameHandler: AppleHEVCDecoder.FrameHandler?
        private var failureHandler: AppleHEVCDecoder.FailureHandler?

        func install(
            frameHandler: @escaping AppleHEVCDecoder.FrameHandler,
            failureHandler: @escaping AppleHEVCDecoder.FailureHandler
        ) {
            lock.lock()
            self.frameHandler = frameHandler
            self.failureHandler = failureHandler
            lock.unlock()
        }

        func emit(_ frame: AppleHEVCDecoder.DecodedFrame) {
            let handler = locked { frameHandler }
            handler?(frame)
        }

        func emit(_ failure: AppleHEVCDecoder.DecodeFailure) {
            let handler = locked { failureHandler }
            handler?(failure)
        }

        func clear() {
            lock.lock()
            frameHandler = nil
            failureHandler = nil
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
    private let frameHandler: FrameHandler
    private let refreshHandler: RefreshHandler
    private let errorHandler: ErrorHandler
    private let callbackBridge: CallbackBridge
    private var decoder: (any AppleHEVCDecodeSubmitting)?
    private var admission = AppleHEVCDecodingOrderQueue()
    private var playoutClock = AppleVideoPlayoutClock()
    private var lastRefreshRequestTimestamp: UInt32?
    private var isClosed = false
    private let freezeDiagnosticsEnabled = ProcessInfo.processInfo.environment[
        "ISHARESCREEN_FREEZE_DIAGNOSTICS"
    ] == "1"

    init(
        tileCount: Int,
        sourceToTile: [UInt32: Int],
        callbackQueue: DispatchQueue,
        decoderFactory: DecoderFactory,
        frameHandler: @escaping FrameHandler,
        refreshHandler: @escaping RefreshHandler,
        errorHandler: @escaping ErrorHandler
    ) throws {
        precondition(tileCount > 0)
        precondition(sourceToTile.count == tileCount)
        self.sourceToTile = sourceToTile
        self.callbackQueue = callbackQueue
        self.frameHandler = frameHandler
        self.refreshHandler = refreshHandler
        self.errorHandler = errorHandler
        callbackBridge = CallbackBridge()
        decoder = nil

        decoder = try makeDecoder(using: decoderFactory)
        callbackBridge.install(
            frameHandler: { [weak self, callbackQueue] frame in
                callbackQueue.async { [weak self] in
                    self?.handleDecodedFrame(frame)
                }
            },
            failureHandler: { [weak self, callbackQueue] failure in
                callbackQueue.async { [weak self] in
                    self?.handleDecodeFailure(failure)
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
                _ = try decoder?.decode(
                    accessUnit.nalUnits,
                    tileIndex: tileIndex,
                    decodingOrderNumber: accessUnit.decodingOrderNumber,
                    rtpTimestamp: accessUnit.timestamp,
                    presentationTime: presentationTime
                )
            } catch let AppleHEVCDecoderError.decodeFailed(status) {
                if status == kVTVideoDecoderReferenceMissingErr {
                    requestRefreshIfNeeded(for: accessUnit.timestamp)
                }
                logFreezeDiagnostic(
                    "synchronous status=\(status) rtp=\(accessUnit.timestamp); continuing submissions"
                )
                Self.logger.notice(
                    "Synchronous video decode failure status=\(status, privacy: .public); continuing submissions"
                )
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

    /// Replaces only the decompression session for a new video format. RTP
    /// admission and playout anchoring remain continuous across the change.
    func replaceDecoder(using decoderFactory: DecoderFactory) throws {
        guard !isClosed else { throw AppleHEVCDecoderError.sessionClosed }
        decoder?.close()
        decoder = nil
        decoder = try makeDecoder(using: decoderFactory)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        callbackBridge.clear()
        decoder?.close()
        decoder = nil
    }

    deinit {
        close()
    }

    private func handleDecodeFailure(_ failure: AppleHEVCDecoder.DecodeFailure) {
        guard !isClosed else { return }
        if failure.status == kVTVideoDecoderReferenceMissingErr {
            requestRefreshIfNeeded(for: failure.rtpTimestamp)
        }
        logFreezeDiagnostic(
            "asynchronous status=\(failure.status) rtp=\(failure.rtpTimestamp); continuing submissions"
        )
        Self.logger.notice(
            "Asynchronous video decode failure tile=\(failure.tileIndex, privacy: .public) status=\(failure.status, privacy: .public); continuing submissions"
        )
    }

    private func makeDecoder(using decoderFactory: DecoderFactory) throws
        -> any AppleHEVCDecodeSubmitting {
        try decoderFactory(
            { [callbackBridge] failure in
                callbackBridge.emit(failure)
            },
            { [callbackBridge] frame in
                callbackBridge.emit(frame)
            }
        )
    }

    private func handleDecodedFrame(_ frame: AppleHEVCDecoder.DecodedFrame) {
        guard !isClosed else { return }
        frameHandler(frame)
    }

    private func requestRefreshIfNeeded(for timestamp: UInt32) {
        guard timestamp != lastRefreshRequestTimestamp else { return }
        lastRefreshRequestTimestamp = timestamp
        refreshHandler(timestamp)
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
