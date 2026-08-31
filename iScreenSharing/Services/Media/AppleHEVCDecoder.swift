import CoreMedia
import CoreVideo
import Foundation
import OSLog
import QuartzCore
import enum ScreenSharingProtocol.AppleHEVCNALUnit
import enum ScreenSharingProtocol.AppleMediaOffer
import VideoToolbox

final class AppleHEVCDecoder: @unchecked Sendable {
    enum Backend: String, Equatable, Sendable {
        case videoProcessing = "VCP"
        case videoToolbox = "VT"
    }

    enum FrameRegion: Equatable, Sendable {
        case tile(Int)
        case fullCanvas
    }

    struct DecodedFrame: @unchecked Sendable {
        let region: FrameRegion
        let decodingOrderNumber: UInt16?
        let rtpTimestamp: UInt32
        let presentationTime: TimeInterval
        let decodeDuration: TimeInterval
        let accessUnitTiming: AppleHEVCAccessUnit.Timing?
        let decodeEnteredAt: TimeInterval
        let decoderSubmittedAt: TimeInterval
        let decoderOutputAt: TimeInterval
        let pixelBuffer: CVPixelBuffer
    }

    struct DecodeFailure: Equatable, Sendable {
        enum Reason: String, Equatable, Sendable {
            case decoderStatus
            case frameDropped
            case missingImageBuffer
        }

        let tileIndex: Int
        let rtpTimestamp: UInt32
        let frameSequenceNumber: UInt16?
        let status: OSStatus
        let reason: Reason

        init(
            tileIndex: Int,
            rtpTimestamp: UInt32,
            frameSequenceNumber: UInt16? = nil,
            status: OSStatus,
            reason: Reason = .decoderStatus
        ) {
            self.tileIndex = tileIndex
            self.rtpTimestamp = rtpTimestamp
            self.frameSequenceNumber = frameSequenceNumber
            self.status = status
            self.reason = reason
        }
    }

    enum VideoToolboxOutputDisposition: Equatable {
        case frame
        case failure(DecodeFailure.Reason)
    }

    typealias FrameHandler = @Sendable (DecodedFrame) -> Void
    typealias FailureHandler = @Sendable (DecodeFailure) -> Void
    typealias BackendHandler = @Sendable (Backend) -> Void
    typealias LongTermReferenceHandler = @Sendable (UInt16) -> Void

    static let nativePixelFormat = OSType(0x3434_3466) // '444f' (NV24)
    static let decodeFlags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
    private static let logger = Logger(
        subsystem: "com.wangkai.iShareScreen",
        category: "VideoDecoder"
    )
    private static let freezeDiagnosticsEnabled = ProcessInfo.processInfo.environment[
        "ISHARESCREEN_FREEZE_DIAGNOSTICS"
    ] == "1"

    private enum Session {
        case videoProcessing(AppleVCPDecompressionSession)
        case videoToolbox(VTDecompressionSession)

        var backend: Backend {
            switch self {
            case .videoProcessing: .videoProcessing
            case .videoToolbox: .videoToolbox
            }
        }

        func close() {
            switch self {
            case let .videoProcessing(session):
                session.close()
            case let .videoToolbox(session):
                AppleHEVCDecoder.invalidate(session)
            }
        }
    }

    private let lock = NSLock()
    private let warningLock = NSLock()
    private let formatDescription: CMVideoFormatDescription
    private let tileCount: Int
    private let frameHandler: FrameHandler
    private let failureHandler: FailureHandler
    private let backendHandler: BackendHandler
    private let longTermReferenceHandler: LongTermReferenceHandler
    private var session: Session?
    private var nextVideoProcessingTileOrder: UInt16 = 0
    private var warnedPixelFormats = Set<OSType>()

    init(
        parameterSets: AppleHEVCParameterSets,
        tileCount: Int = 1,
        decoderMode: AppleVideoDecoderMode = .automatic,
        backendHandler: @escaping BackendHandler = { _ in },
        failureHandler: @escaping FailureHandler = { _ in },
        longTermReferenceHandler: @escaping LongTermReferenceHandler = { _ in },
        frameHandler: @escaping FrameHandler
    ) throws {
        guard parameterSets.isComplete else { throw AppleHEVCDecoderError.incompleteParameterSets }
        guard tileCount > 0 else { throw AppleHEVCDecoderError.invalidTileCount }
        formatDescription = try Self.makeFormatDescription(parameterSets)
        self.tileCount = tileCount
        self.backendHandler = backendHandler
        self.failureHandler = failureHandler
        self.longTermReferenceHandler = longTermReferenceHandler
        self.frameHandler = frameHandler
        let session = try makeSession(decoderMode: decoderMode)
        self.session = session
        backendHandler(session.backend)
    }

    var backend: Backend {
        lock.withDecoderLock { session?.backend ?? .videoToolbox }
    }

    @discardableResult
    func decode(
        _ nalUnits: [Data],
        tileIndex: Int,
        decodingOrderNumber: UInt16?,
        isLongTermReferenceFrame: Bool,
        rtpTimestamp: UInt32,
        presentationTime: TimeInterval,
        timing: AppleHEVCAccessUnit.Timing?
    ) throws -> Bool {
        try Self.validateTileIndex(tileIndex, tileCount: tileCount)
        let validNALUnits = nalUnits.filter { AppleHEVCNALUnit.type(of: $0) != nil }
        guard validNALUnits.contains(where: {
            guard let type = AppleHEVCNALUnit.type(of: $0) else { return false }
            return type < 32
        }) else { return false }
        let decodeEnteredAt = CACurrentMediaTime()
        return try lock.withDecoderLock {
            guard let session else { throw AppleHEVCDecoderError.sessionClosed }
            switch session {
            case let .videoProcessing(session):
                let sampleBuffer = try Self.makeSampleBuffer(
                    nalUnits: validNALUnits,
                    formatDescription: formatDescription,
                    presentationTime: presentationTime
                )
                // AVConference normally forwards DON as TileOrder because its
                // transmitter and VCP receiver both start at zero. We may join
                // after the transmitter has advanced, while VCP still requires
                // the first submitted TileOrder to be zero, so rebase DON to a
                // session-local monotonic sequence.
                let tileOrder = Self.takeVideoProcessingTileOrder(
                    from: &nextVideoProcessingTileOrder
                )
                do {
                    return try session.decode(
                        sampleBuffer,
                        metadata: AppleVCPDecompressionSession.FrameMetadata(
                            tileIndex: tileIndex,
                            tileOrder: tileOrder,
                            decodingOrderNumber: decodingOrderNumber,
                            isLongTermReferenceFrame: isLongTermReferenceFrame,
                            rtpTimestamp: rtpTimestamp,
                            presentationTime: presentationTime,
                            accessUnitTiming: timing,
                            decodeEnteredAt: decodeEnteredAt,
                            decoderSubmittedAt: 0
                        ),
                        flags: Self.decodeFlags
                    )
                } catch let error as AppleVCPDecompressionSessionError {
                    switch error {
                    case let .decodeFailed(status):
                        nextVideoProcessingTileOrder = tileOrder
                        throw AppleHEVCDecoderError.decodeFailed(status)
                    case .sessionClosed:
                        throw AppleHEVCDecoderError.sessionClosed
                    }
                }
            case let .videoToolbox(session):
                let sampleBuffer = try Self.makeSampleBuffer(
                    nalUnits: validNALUnits,
                    formatDescription: formatDescription,
                    presentationTime: presentationTime
                )
                var decodeInfo = VTDecodeInfoFlags()
                let decoderSubmittedAt = CACurrentMediaTime()
                let status = VTDecompressionSessionDecodeFrame(
                    session,
                    sampleBuffer: sampleBuffer,
                    flags: Self.decodeFlags,
                    infoFlagsOut: &decodeInfo
                ) { [frameHandler, failureHandler, longTermReferenceHandler] status, infoFlags, imageBuffer, _, _ in
                    let disposition = Self.videoToolboxOutputDisposition(
                        status: status,
                        infoFlags: infoFlags,
                        hasImageBuffer: imageBuffer != nil
                    )
                    guard disposition == .frame, let imageBuffer else {
                        guard case let .failure(reason) = disposition else { return }
                        failureHandler(DecodeFailure(
                            tileIndex: tileIndex,
                            rtpTimestamp: rtpTimestamp,
                            frameSequenceNumber: timing?.observedFrameSequenceNumber,
                            status: status,
                            reason: reason
                        ))
                        return
                    }
                    if isLongTermReferenceFrame,
                       let decodingOrderNumber,
                       decodingOrderNumber != 0 {
                        longTermReferenceHandler(decodingOrderNumber)
                    }
                    let decoderOutputAt = CACurrentMediaTime()
                    frameHandler(DecodedFrame(
                        region: .tile(tileIndex),
                        decodingOrderNumber: decodingOrderNumber,
                        rtpTimestamp: rtpTimestamp,
                        presentationTime: presentationTime,
                        decodeDuration: decoderOutputAt - decodeEnteredAt,
                        accessUnitTiming: timing,
                        decodeEnteredAt: decodeEnteredAt,
                        decoderSubmittedAt: decoderSubmittedAt,
                        decoderOutputAt: decoderOutputAt,
                        pixelBuffer: imageBuffer
                    ))
                }
                guard status == noErr else { throw AppleHEVCDecoderError.decodeFailed(status) }
                return true
            }
        }
    }

    func close() {
        lock.withDecoderLock {
            guard let session else { return }
            session.close()
            self.session = nil
        }
    }

    deinit {
        close()
    }

    static func lengthPrefixedPayload(for nalUnit: Data) throws -> Data {
        try lengthPrefixedPayload(for: [nalUnit])
    }

    static func lengthPrefixedPayload(for nalUnits: [Data]) throws -> Data {
        guard !nalUnits.isEmpty,
              nalUnits.allSatisfy({ !$0.isEmpty && $0.count <= Int(UInt32.max) }) else {
            throw AppleHEVCDecoderError.invalidNALUnit
        }
        var payload = Data()
        for nalUnit in nalUnits {
            payload.appendUInt32BE(UInt32(nalUnit.count))
            payload.append(nalUnit)
        }
        return payload
    }

    static func requiresReplacement(
        configured: AppleHEVCParameterSets,
        current: AppleHEVCParameterSets
    ) -> Bool {
        current.isComplete && current != configured
    }

    static func prefersVideoProcessing(
        mode: AppleVideoDecoderMode = .automatic,
        tileCount: Int,
        isAvailable: Bool
    ) -> Bool {
        mode != .videoToolboxLowLatency
            && mode != .videoToolboxSynchronized
            && tileCount == 4
            && isAvailable
    }

    static func takeVideoProcessingTileOrder(from nextOrder: inout UInt16) -> UInt16 {
        let order = nextOrder
        nextOrder &+= 1
        return order
    }

    static func videoToolboxOutputDisposition(
        status: OSStatus,
        infoFlags: VTDecodeInfoFlags,
        hasImageBuffer: Bool
    ) -> VideoToolboxOutputDisposition {
        if status != noErr { return .failure(.decoderStatus) }
        if infoFlags.contains(.frameDropped) { return .failure(.frameDropped) }
        if !hasImageBuffer { return .failure(.missingImageBuffer) }
        return .frame
    }

    static func validateTileIndex(_ tileIndex: Int, tileCount: Int) throws {
        guard tileIndex >= 0, tileIndex < tileCount else {
            throw AppleHEVCDecoderError.invalidTileIndex
        }
    }

    private func makeSession(decoderMode: AppleVideoDecoderMode) throws -> Session {
        if Self.prefersVideoProcessing(
            mode: decoderMode,
            tileCount: tileCount,
            isAvailable: AppleVCPDecompressionSession.isAvailable
        ), let session = AppleVCPDecompressionSession(
            formatDescription: formatDescription,
            tileCount: tileCount,
            negotiationDetails: AppleMediaOffer.videoDecoderNegotiationDetails,
            nativePixelFormat: Self.nativePixelFormat,
            failureHandler: { [weak self] metadata, status in
                self?.failureHandler(DecodeFailure(
                    tileIndex: metadata.tileIndex,
                    rtpTimestamp: metadata.rtpTimestamp,
                    frameSequenceNumber:
                        metadata.accessUnitTiming?.observedFrameSequenceNumber,
                    status: status
                ))
            },
            successfulDecodeHandler: { [weak self] metadata in
                self?.acknowledgeLongTermReferenceIfNeeded(metadata)
            },
            frameHandler: { [weak self] metadata, pixelBuffer in
                self?.publishFullCanvas(pixelBuffer, metadata: metadata)
            }
        ) {
            Self.logger.notice("Using native VideoProcessing multi-tile assembly")
            return .videoProcessing(session)
        }
        if tileCount > 1 {
            Self.logger.warning(
                "Using one public VideoToolbox decoder with incremental tile updates and atomic Metal presentation"
            )
        }
        return .videoToolbox(try Self.makeVideoToolboxSession(
            formatDescription: formatDescription
        ))
    }

    private func publishFullCanvas(
        _ pixelBuffer: CVPixelBuffer,
        metadata: AppleVCPDecompressionSession.FrameMetadata
    ) {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if pixelFormat != Self.nativePixelFormat {
            warningLock.withDecoderLock {
                guard warnedPixelFormats.insert(pixelFormat).inserted else { return }
                Self.logger.error(
                    "VideoProcessing returned unsupported pixel format \(pixelFormat, privacy: .public)"
                )
            }
        }
        let decoderOutputAt = CACurrentMediaTime()
        frameHandler(DecodedFrame(
            region: .fullCanvas,
            decodingOrderNumber: metadata.decodingOrderNumber,
            rtpTimestamp: metadata.rtpTimestamp,
            presentationTime: metadata.presentationTime,
            decodeDuration: decoderOutputAt - metadata.decodeEnteredAt,
            accessUnitTiming: metadata.accessUnitTiming,
            decodeEnteredAt: metadata.decodeEnteredAt,
            decoderSubmittedAt: metadata.decoderSubmittedAt,
            decoderOutputAt: decoderOutputAt,
            pixelBuffer: pixelBuffer
        ))
    }

    private func acknowledgeLongTermReferenceIfNeeded(
        _ metadata: AppleVCPDecompressionSession.FrameMetadata
    ) {
        guard metadata.isLongTermReferenceFrame,
              let decodingOrderNumber = metadata.decodingOrderNumber,
              decodingOrderNumber != 0 else { return }
        longTermReferenceHandler(decodingOrderNumber)
    }

    private static func makeFormatDescription(
        _ parameterSets: AppleHEVCParameterSets
    ) throws -> CMVideoFormatDescription {
        let data = [parameterSets.video, parameterSets.sequence] + parameterSets.pictures
        let retainedData = data.map { $0 as NSData }
        var pointers = retainedData.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        var sizes = retainedData.map(\.length)
        var description: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: pointers.count,
            parameterSetPointers: &pointers,
            parameterSetSizes: &sizes,
            nalUnitHeaderLength: 4,
            extensions: nil,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw AppleHEVCDecoderError.formatDescriptionCreationFailed(status)
        }
        return description
    }

    private static func makeVideoToolboxSession(
        formatDescription: CMVideoFormatDescription
    ) throws -> VTDecompressionSession {
        var session: VTDecompressionSession?
        let attributes = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: nativePixelFormat),
        ] as CFDictionary
        var status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attributes,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        if status != noErr || session == nil {
            status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: formatDescription,
                decoderSpecification: nil,
                imageBufferAttributes: nil,
                outputCallback: nil,
                decompressionSessionOut: &session
            )
        }
        guard status == noErr, let session else {
            throw AppleHEVCDecoderError.sessionCreationFailed(status)
        }
        return session
    }

    private static func invalidate(_ session: VTDecompressionSession) {
        let startedAt = CACurrentMediaTime()
        if freezeDiagnosticsEnabled {
            logger.notice("[DEBUG-VTSTALL-91C7] wait begin backend=VT")
        }
        let status = VTDecompressionSessionWaitForAsynchronousFrames(session)
        if freezeDiagnosticsEnabled {
            logger.notice(
                "[DEBUG-VTSTALL-91C7] wait end backend=VT status=\(status, privacy: .public) duration=\((CACurrentMediaTime() - startedAt) * 1_000, format: .fixed(precision: 2))ms"
            )
        }
        VTDecompressionSessionInvalidate(session)
    }

    private static func makeSampleBuffer(
        nalUnits: [Data],
        formatDescription: CMVideoFormatDescription,
        presentationTime: TimeInterval
    ) throws -> CMSampleBuffer {
        let payload = try lengthPrefixedPayload(for: nalUnits)
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw AppleHEVCDecoderError.sampleBufferCreationFailed(status)
        }
        status = payload.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: payload.count
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw AppleHEVCDecoderError.sampleBufferCreationFailed(status)
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = payload.count
        var sampleTiming = compressedSampleTiming(presentationTime: presentationTime)
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &sampleTiming,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw AppleHEVCDecoderError.sampleBufferCreationFailed(status)
        }
        return sampleBuffer
    }

    static func compressedSampleTiming(presentationTime: TimeInterval) -> CMSampleTimingInfo {
        let nanoseconds = Int64(presentationTime * 1_000_000_000)
        return CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 1),
            presentationTimeStamp: CMTime(value: nanoseconds, timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
    }
}

enum AppleHEVCDecoderError: LocalizedError, Equatable {
    case incompleteParameterSets
    case invalidTileCount
    case invalidTileIndex
    case invalidNALUnit
    case formatDescriptionCreationFailed(OSStatus)
    case sessionCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
    case decodeFailed(OSStatus)
    case sessionClosed

    var errorDescription: String? {
        switch self {
        case .incompleteParameterSets:
            "The remote Mac did not provide complete HEVC decoder parameters."
        case .invalidTileCount:
            "The remote Mac provided an invalid HEVC tile count."
        case .invalidTileIndex:
            "A video tile was routed outside the configured decoder set."
        case .invalidNALUnit:
            "The remote Mac sent an invalid HEVC video unit."
        case .formatDescriptionCreationFailed, .sessionCreationFailed:
            "The Mac could not prepare its hardware video decoder."
        case .sampleBufferCreationFailed, .decodeFailed:
            "A remote video frame could not be decoded."
        case .sessionClosed:
            "The remote video decoder is no longer active."
        }
    }
}

private extension NSLock {
    func withDecoderLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
