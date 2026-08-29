import CoreVideo
import Foundation
import OSLog

final class StandardRFBVideoStream: SessionVideoStream, @unchecked Sendable {
    private static let maximumFramebufferBytes = 256 * 1_024 * 1_024
    private static let logger = Logger(
        subsystem: "com.wangkai.iShareScreen",
        category: "StandardRFB"
    )

    private weak var session: RFBAuthenticatedSession?
    private var quality: StandardRFBQuality
    private let pixelFormat: StandardRFBPixelFormat
    private let zlibDecoder: StandardRFBZlibDecoder
    private let halftoneZlibDecoder: StandardRFBZlibDecoder
    private let grayscaleZlibDecoder: StandardRFBZlibDecoder
    private let thousandsZlibDecoder: StandardRFBZlibDecoder
    private let lifecycleLock = NSLock()
    private let framebufferStateLock = NSLock()
    private var initialConfigurationTask: Task<Void, Error>?
    private var receiveTask: Task<Void, Never>?
    private var framebuffer: Data
    private var framebufferPool: CVPixelBufferPool
    private var framebufferCanvas: AppleCanvas
    private var initialCoverage: StandardRFBRegionCoverage
    private var automaticUpdatesEnabled = false
    private var frameCount = 0
    // Rectangle writes happen only while this flag is set. Display requests
    // either snapshot the last complete generation or wait for this FBU to
    // finish, so the renderer can never observe a partially applied update.
    private var framebufferUpdateInProgress = false
    private var displayDrivenFrameRequestsEnabled = false
    private var displayFrameRequested = false
    private var completedFramebufferGeneration: UInt64 = 0
    private var publishedFramebufferGeneration: UInt64 = 0
    private var pendingInitialQuality: StandardRFBQuality?
    private var needsInitialRefreshConfirmation: Bool
    private var publicationMetrics = PublicationMetrics()
    private var processingMetrics = ProcessingMetrics()

    private struct PublicationMetrics {
        var frames = 0
        var duration = 0.0
    }

    private struct ProcessingMetrics {
        var startedAt = ProcessInfo.processInfo.systemUptime
        var updates = 0
        var rawRectangles = 0
        var copyRectangles = 0
        var zlibRectangles = 0
        var halftoneRectangles = 0
        var grayscaleRectangles = 0
        var thousandsRectangles = 0
        var hextileRectangles = 0
        var sourceBytes = 0
        var pixels = 0
        var inflateDuration = 0.0
        var applyDuration = 0.0
        var hextileDuration = 0.0
    }

    private struct CompressedRectangleResult {
        let sourceByteCount: Int
        let pixelCount: Int
        let inflateDuration: TimeInterval
        let applyDuration: TimeInterval

        var duration: TimeInterval { inflateDuration + applyDuration }
    }

    init(session: RFBAuthenticatedSession, quality: StandardRFBQuality) throws {
        self.session = session
        self.quality = quality
        pixelFormat = .standard
        zlibDecoder = try StandardRFBZlibDecoder()
        halftoneZlibDecoder = try StandardRFBZlibDecoder()
        grayscaleZlibDecoder = try StandardRFBZlibDecoder()
        thousandsZlibDecoder = try StandardRFBZlibDecoder()
        let qualityProfile = StandardRFBMessages.qualityProfile(for: quality)
        pendingInitialQuality = qualityProfile.startupQuality == quality ? nil : quality
        needsInitialRefreshConfirmation = pendingInitialQuality == nil
            && qualityProfile.requiresInitialRefreshConfirmation
        let canvas = AppleCanvas(
            width: Int(session.serverInfo.width),
            height: Int(session.serverInfo.height),
            tileCount: 1
        )
        framebufferCanvas = canvas
        framebuffer = try Self.makeFramebuffer(width: canvas.width, height: canvas.height)
        framebufferPool = try Self.makePixelBufferPool(width: canvas.width, height: canvas.height)
        initialCoverage = StandardRFBRegionCoverage(width: canvas.width, height: canvas.height)
        super.init(canvas: canvas, displayIndex: 0, tileCount: 1)
        Self.logger.info(
            "Configured Standard stream quality=\(quality.rawValue, privacy: .public) size=\(canvas.width)x\(canvas.height)"
        )
    }

    override var decodedFrameCount: Int {
        lifecycleLock.withStandardStreamLock { frameCount }
    }

    var currentQuality: StandardRFBQuality {
        lifecycleLock.withStandardStreamLock { quality }
    }

    override var presentsFramesOnlyOnDisplayLink: Bool { true }

    override func setDisplayDrivenFrameRequestsEnabled(_ enabled: Bool) {
        framebufferStateLock.lock()
        displayDrivenFrameRequestsEnabled = enabled
        if !enabled {
            displayFrameRequested = false
            publishLatestFramebufferIfIdleLocked()
        }
        framebufferStateLock.unlock()
    }

    override func requestFrameForDisplay() {
        framebufferStateLock.lock()
        displayFrameRequested = true
        publishLatestFramebufferIfIdleLocked()
        framebufferStateLock.unlock()
    }

    func setQuality(_ quality: StandardRFBQuality) async throws {
        guard quality != currentQuality else { return }
        guard let session else { throw CancellationError() }
        try Task.checkCancellation()
        let initialConfigurationTask = lifecycleLock.withStandardStreamLock {
            self.initialConfigurationTask
        }
        try await initialConfigurationTask?.value
        try await session.sendStandard([
            StandardRFBMessages.setEncodings(for: quality),
            AppleRFBMessages.framebufferUpdateRequest(
                width: UInt16(framebufferCanvas.width),
                height: UInt16(framebufferCanvas.height)
            ),
        ])
        lifecycleLock.withStandardStreamLock {
            self.quality = quality
            pendingInitialQuality = nil
        }
        Self.logger.info("Changed Standard quality=\(quality.rawValue, privacy: .public)")
    }

    override func start() {
        guard let session else { return }
        let task = lifecycleLock.withStandardStreamLock { () -> Task<Void, Never>? in
            guard receiveTask == nil else { return nil }
            let initialQuality = quality
            let initialProfile = StandardRFBMessages.qualityProfile(for: initialQuality)
            let configurationTask = Task {
                try await session.sendStandard([
                    StandardRFBMessages.setPixelFormat(.standard),
                    StandardRFBMessages.setEncodings(for: initialProfile.startupQuality),
                    AppleRFBMessages.framebufferUpdateRequest(
                        width: session.serverInfo.width,
                        height: session.serverInfo.height
                    ),
                ])
            }
            initialConfigurationTask = configurationTask
            let task = Task { [weak self] in
                guard let self else { return }
                await self.run(after: configurationTask)
            }
            receiveTask = task
            return task
        }
        if task != nil { publishState(.preparing) }
    }

    override func close() {
        let tasks = lifecycleLock.withStandardStreamLock {
            let tasks = (initialConfigurationTask, receiveTask)
            initialConfigurationTask = nil
            receiveTask = nil
            return tasks
        }
        tasks.0?.cancel()
        tasks.1?.cancel()
        publishState(.stopped)
    }

    private func run(after initialConfigurationTask: Task<Void, Error>) async {
        guard let session else { return }
        do {
            try await initialConfigurationTask.value
            while !Task.isCancelled {
                try await readServerMessage(from: session)
            }
        } catch is CancellationError {
            return
        } catch {
            Self.logger.error(
                "Standard stream failed quality=\(self.currentQuality.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            publishState(.failed(error.localizedDescription))
        }
    }

    private func readServerMessage(from session: RFBAuthenticatedSession) async throws {
        let type = try await receiveStandardBytes(1, from: session)[0]
        switch type {
        case 0:
            try await readFramebufferUpdate(from: session)
        case 1:
            let header = try await receiveStandardBytes(5, from: session)
            let colorCount = Int(try header.uint16BE(at: 3))
            _ = try await receiveStandardBytes(colorCount * 6, from: session)
        case 2:
            break
        case 3:
            let header = try await receiveStandardBytes(7, from: session)
            let length = Int(try header.uint32BE(at: 3))
            guard length <= Self.maximumFramebufferBytes else {
                throw StandardRFBError.framebufferTooLarge
            }
            _ = try await receiveStandardBytes(length, from: session)
        default:
            throw StandardRFBError.unsupportedServerMessage(type)
        }
    }

    private func readFramebufferUpdate(from session: RFBAuthenticatedSession) async throws {
        let header = try await receiveStandardBytes(3, from: session)
        let rectangleCount = Int(try header.uint16BE(at: 1))
        beginFramebufferUpdate()
        var completedUpdate = false
        defer {
            if !completedUpdate { abandonFramebufferUpdate() }
        }
        var didChange = false
        var requiresFullRefresh = false
        var processingDuration: TimeInterval = 0
        for _ in 0..<rectangleCount {
            let rectangle = try await receiveStandardBytes(12, from: session)
            let x = Int(try rectangle.uint16BE(at: 0))
            let y = Int(try rectangle.uint16BE(at: 2))
            let width = Int(try rectangle.uint16BE(at: 4))
            let height = Int(try rectangle.uint16BE(at: 6))
            let encoding = try rectangle.int32BE(at: 8)
            switch encoding {
            case StandardRFBMessages.rawEncoding:
                let pixelCount = try Self.checkedPixelCount(width: width, height: height)
                let payload = try await receiveStandardBytes(
                    pixelCount * pixelFormat.bytesPerPixel,
                    from: session
                )
                let startedAt = ProcessInfo.processInfo.systemUptime
                try applyRawRectangle(payload, x: x, y: y, width: width, height: height)
                let duration = ProcessInfo.processInfo.systemUptime - startedAt
                processingDuration += duration
                processingMetrics.rawRectangles += 1
                processingMetrics.sourceBytes += payload.count
                processingMetrics.pixels += pixelCount
                processingMetrics.applyDuration += duration
                initialCoverage.mark(x: x, y: y, width: width, height: height)
                didChange = true
            case StandardRFBMessages.copyRectangleEncoding:
                let source = try await receiveStandardBytes(4, from: session)
                let startedAt = ProcessInfo.processInfo.systemUptime
                try applyCopyRectangle(
                    sourceX: Int(try source.uint16BE(at: 0)),
                    sourceY: Int(try source.uint16BE(at: 2)),
                    destinationX: x,
                    destinationY: y,
                    width: width,
                    height: height
                )
                let duration = ProcessInfo.processInfo.systemUptime - startedAt
                processingDuration += duration
                processingMetrics.copyRectangles += 1
                processingMetrics.pixels += width * height
                processingMetrics.applyDuration += duration
                if initialCoverage.covers(
                    x: Int(try source.uint16BE(at: 0)),
                    y: Int(try source.uint16BE(at: 2)),
                    width: width,
                    height: height
                ) {
                    initialCoverage.mark(x: x, y: y, width: width, height: height)
                }
                didChange = true
            case StandardRFBMessages.zlibEncoding:
                let pixelCount = try Self.checkedPixelCount(width: width, height: height)
                let result = try await readCompressedRectangle(
                    from: session,
                    decoder: zlibDecoder,
                    expectedSize: pixelCount * pixelFormat.bytesPerPixel,
                    pixelCount: pixelCount
                ) { payload in
                    try applyRawRectangle(payload, x: x, y: y, width: width, height: height)
                }
                processingDuration += result.duration
                processingMetrics.zlibRectangles += 1
                record(result)
                initialCoverage.mark(x: x, y: y, width: width, height: height)
                didChange = true
            case StandardRFBMessages.subZlibHalftoneEncoding:
                let pixelCount = try Self.checkedPixelCount(width: width, height: height)
                let expectedSize = try StandardRFBHalftoneDecoder.packedByteCount(
                    width: width,
                    height: height
                )
                let result = try await readCompressedRectangle(
                    from: session,
                    decoder: halftoneZlibDecoder,
                    expectedSize: expectedSize,
                    pixelCount: pixelCount
                ) { payload in
                    try applyHalftoneRectangle(payload, x: x, y: y, width: width, height: height)
                }
                processingDuration += result.duration
                processingMetrics.halftoneRectangles += 1
                record(result)
                initialCoverage.mark(x: x, y: y, width: width, height: height)
                didChange = true
            case StandardRFBMessages.subZlib16GrayEncoding:
                let pixelCount = try Self.checkedPixelCount(width: width, height: height)
                let expectedSize = try StandardRFBGrayscaleDecoder.packedByteCount(
                    width: width,
                    height: height
                )
                let result = try await readCompressedRectangle(
                    from: session,
                    decoder: grayscaleZlibDecoder,
                    expectedSize: expectedSize,
                    pixelCount: pixelCount
                ) { payload in
                    try applyGrayscaleRectangle(payload, x: x, y: y, width: width, height: height)
                }
                processingDuration += result.duration
                processingMetrics.grayscaleRectangles += 1
                record(result)
                initialCoverage.mark(x: x, y: y, width: width, height: height)
                didChange = true
            case StandardRFBMessages.subZlibThousandsEncoding:
                let pixelCount = try Self.checkedPixelCount(width: width, height: height)
                let expectedSize = try StandardRFBThousandsDecoder.packedByteCount(
                    width: width,
                    height: height
                )
                let result = try await readCompressedRectangle(
                    from: session,
                    decoder: thousandsZlibDecoder,
                    expectedSize: expectedSize,
                    pixelCount: pixelCount
                ) { payload in
                    try applyThousandsRectangle(payload, x: x, y: y, width: width, height: height)
                }
                processingDuration += result.duration
                processingMetrics.thousandsRectangles += 1
                record(result)
                initialCoverage.mark(x: x, y: y, width: width, height: height)
                didChange = true
            case StandardRFBMessages.hextileEncoding:
                let startedAt = ProcessInfo.processInfo.systemUptime
                let pixels = try await StandardRFBHextileDecoder.decode(
                    width: width,
                    height: height,
                    pixelFormat: pixelFormat,
                    read: { try await self.receiveStandardBytes($0, from: session) }
                )
                try applyBGRARectangle(pixels, x: x, y: y, width: width, height: height)
                let duration = ProcessInfo.processInfo.systemUptime - startedAt
                processingDuration += duration
                processingMetrics.hextileRectangles += 1
                processingMetrics.pixels += width * height
                processingMetrics.hextileDuration += duration
                initialCoverage.mark(x: x, y: y, width: width, height: height)
                didChange = true
            case StandardRFBMessages.desktopSizeEncoding:
                try await resize(width: width, height: height)
                requiresFullRefresh = true
            default:
                throw StandardRFBError.unsupportedEncoding(encoding)
            }
        }
        let hasCompleteCoverage = didChange && initialCoverage.isComplete
        let requiresInitialRefreshConfirmation = hasCompleteCoverage
            && needsInitialRefreshConfirmation
        if requiresInitialRefreshConfirmation {
            needsInitialRefreshConfirmation = false
            initialCoverage = StandardRFBRegionCoverage(
                width: framebufferCanvas.width,
                height: framebufferCanvas.height
            )
        }
        let isPublishable = hasCompleteCoverage && !requiresInitialRefreshConfirmation
        let initialQualityTransition = isPublishable
            ? lifecycleLock.withStandardStreamLock { () -> StandardRFBQuality? in
                defer { pendingInitialQuality = nil }
                return pendingInitialQuality
            }
            : nil
        if let initialQualityTransition {
            initialCoverage = StandardRFBRegionCoverage(
                width: framebufferCanvas.width,
                height: framebufferCanvas.height
            )
            needsInitialRefreshConfirmation = StandardRFBMessages
                .qualityProfile(for: initialQualityTransition)
                .requiresInitialRefreshConfirmation
        }
        if isPublishable {
            processingMetrics.updates += 1
        }
        let publishDuration = try completeFramebufferUpdate(isPublishable: isPublishable)
        completedUpdate = true
        processingDuration += publishDuration
        if isPublishable {
            performance.recordDecode(duration: processingDuration)
            logProcessingMetricsIfNeeded()
        }
        if let initialQualityTransition {
            let width = UInt16(framebufferCanvas.width)
            let height = UInt16(framebufferCanvas.height)
            try await session.sendStandard([
                StandardRFBMessages.setEncodings(for: initialQualityTransition),
                AppleRFBMessages.framebufferUpdateRequest(width: width, height: height),
                AppleRFBMessages.autoFramebufferUpdate(width: width, height: height),
            ])
            automaticUpdatesEnabled = true
        } else if requiresFullRefresh {
            let width = UInt16(framebufferCanvas.width)
            let height = UInt16(framebufferCanvas.height)
            try await session.sendStandard([
                AppleRFBMessages.framebufferUpdateRequest(width: width, height: height),
                AppleRFBMessages.autoFramebufferUpdate(width: width, height: height),
            ])
            automaticUpdatesEnabled = true
        } else if requiresInitialRefreshConfirmation {
            try await session.sendStandard([
                AppleRFBMessages.framebufferUpdateRequest(
                    width: UInt16(framebufferCanvas.width),
                    height: UInt16(framebufferCanvas.height)
                ),
            ])
        } else if didChange, !automaticUpdatesEnabled {
            try await session.sendStandard([
                AppleRFBMessages.autoFramebufferUpdate(
                    width: UInt16(framebufferCanvas.width),
                    height: UInt16(framebufferCanvas.height)
                ),
            ])
            automaticUpdatesEnabled = true
        }
    }

    private func receiveStandardBytes(
        _ length: Int,
        from session: RFBAuthenticatedSession
    ) async throws -> Data {
        let data = try await session.receiveExactly(length)
        performance.recordNetwork(packetCount: 0, byteCount: data.count)
        return data
    }

    private func readCompressedRectangle(
        from session: RFBAuthenticatedSession,
        decoder: StandardRFBZlibDecoder,
        expectedSize: Int,
        pixelCount: Int,
        apply: (Data) throws -> Void
    ) async throws -> CompressedRectangleResult {
        let compressedLength = Int(
            try await receiveStandardBytes(4, from: session).uint32BE(at: 0)
        )
        guard compressedLength > 0,
              compressedLength <= Self.maximumFramebufferBytes else {
            throw StandardRFBError.framebufferTooLarge
        }
        let compressed = try await receiveStandardBytes(compressedLength, from: session)
        let inflateStartedAt = ProcessInfo.processInfo.systemUptime
        let payload = try decoder.decode(compressed, expectedSize: expectedSize)
        let inflateDuration = ProcessInfo.processInfo.systemUptime - inflateStartedAt
        let applyStartedAt = ProcessInfo.processInfo.systemUptime
        try apply(payload)
        return CompressedRectangleResult(
            sourceByteCount: compressed.count,
            pixelCount: pixelCount,
            inflateDuration: inflateDuration,
            applyDuration: ProcessInfo.processInfo.systemUptime - applyStartedAt
        )
    }

    private func record(_ result: CompressedRectangleResult) {
        processingMetrics.sourceBytes += result.sourceByteCount
        processingMetrics.pixels += result.pixelCount
        processingMetrics.inflateDuration += result.inflateDuration
        processingMetrics.applyDuration += result.applyDuration
    }

    private func applyRawRectangle(
        _ payload: Data,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) throws {
        try decodeIntoFramebuffer(x: x, y: y, width: width, height: height) {
            destination, destinationOffset, destinationBytesPerRow in
            try pixelFormat.decodeBGRA(
                payload,
                width: width,
                height: height,
                into: destination,
                destinationOffset: y * destinationBytesPerRow + x * 4,
                destinationBytesPerRow: destinationBytesPerRow
            )
        }
    }

    private func applyHalftoneRectangle(
        _ payload: Data,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) throws {
        try decodeIntoFramebuffer(x: x, y: y, width: width, height: height) {
            destination, destinationOffset, destinationBytesPerRow in
            try StandardRFBHalftoneDecoder.decode(
                payload,
                width: width,
                height: height,
                into: destination,
                destinationOffset: y * destinationBytesPerRow + x * 4,
                destinationBytesPerRow: destinationBytesPerRow
            )
        }
    }

    private func applyGrayscaleRectangle(
        _ payload: Data,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) throws {
        try decodeIntoFramebuffer(x: x, y: y, width: width, height: height) {
            destination, destinationOffset, destinationBytesPerRow in
            try StandardRFBGrayscaleDecoder.decode(
                payload,
                width: width,
                height: height,
                into: destination,
                destinationOffset: y * destinationBytesPerRow + x * 4,
                destinationBytesPerRow: destinationBytesPerRow
            )
        }
    }

    private func applyThousandsRectangle(
        _ payload: Data,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) throws {
        try decodeIntoFramebuffer(x: x, y: y, width: width, height: height) {
            destination, destinationOffset, destinationBytesPerRow in
            try StandardRFBThousandsDecoder.decode(
                payload,
                width: width,
                height: height,
                into: destination,
                destinationOffset: y * destinationBytesPerRow + x * 4,
                destinationBytesPerRow: destinationBytesPerRow
            )
        }
    }

    private func applyCopyRectangle(
        sourceX: Int,
        sourceY: Int,
        destinationX: Int,
        destinationY: Int,
        width: Int,
        height: Int
    ) throws {
        guard sourceX >= 0, sourceY >= 0,
              destinationX >= 0, destinationY >= 0,
              width > 0, height > 0,
              sourceX + width <= framebufferCanvas.width,
              sourceY + height <= framebufferCanvas.height,
              destinationX + width <= framebufferCanvas.width,
              destinationY + height <= framebufferCanvas.height else {
            throw StandardRFBError.invalidRectangle
        }
        let rowBytes = width * 4
        let framebufferRowBytes = framebufferCanvas.width * 4
        var copiedPixels = Data(count: rowBytes * height)
        framebuffer.withUnsafeBytes { source in
            copiedPixels.withUnsafeMutableBytes { destination in
                guard let sourceBase = source.baseAddress,
                      let destinationBase = destination.baseAddress else { return }
                for row in 0..<height {
                    destinationBase.advanced(by: row * rowBytes).copyMemory(
                        from: sourceBase.advanced(
                            by: (sourceY + row) * framebufferRowBytes + sourceX * 4
                        ),
                        byteCount: rowBytes
                    )
                }
            }
        }
        try applyBGRARectangle(
            copiedPixels,
            x: destinationX,
            y: destinationY,
            width: width,
            height: height
        )
    }

    private func applyBGRARectangle(
        _ pixels: Data,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) throws {
        let pixelCount = try Self.checkedPixelCount(width: width, height: height)
        let (byteCount, overflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !overflow, pixels.count == byteCount else {
            throw StandardRFBError.invalidRectangle
        }
        let sourceBytesPerRow = width * 4
        try decodeIntoFramebuffer(x: x, y: y, width: width, height: height) {
            destination, destinationOffset, destinationBytesPerRow in
            try pixels.withUnsafeBytes { source in
                guard let sourceBase = source.baseAddress,
                      let destinationBase = destination.baseAddress else {
                    throw StandardRFBError.invalidRectangle
                }
                for row in 0..<height {
                    destinationBase.advanced(by: destinationOffset + row * destinationBytesPerRow)
                        .copyMemory(
                            from: sourceBase.advanced(by: row * sourceBytesPerRow),
                            byteCount: sourceBytesPerRow
                        )
                }
            }
        }
    }

    private func decodeIntoFramebuffer(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        decode: (
            UnsafeMutableRawBufferPointer,
            _ destinationOffset: Int,
            _ destinationBytesPerRow: Int
        ) throws -> Void
    ) throws {
        guard x >= 0, y >= 0, width > 0, height > 0,
              x + width <= framebufferCanvas.width,
              y + height <= framebufferCanvas.height else {
            throw StandardRFBError.invalidRectangle
        }
        let destinationBytesPerRow = framebufferCanvas.width * 4
        try framebuffer.withUnsafeMutableBytes { destination in
            try decode(
                destination,
                y * destinationBytesPerRow + x * 4,
                destinationBytesPerRow
            )
        }
    }

    private func resize(width: Int, height: Int) async throws {
        let newFramebuffer = try Self.makeFramebuffer(width: width, height: height)
        let newFramebufferPool = try Self.makePixelBufferPool(width: width, height: height)
        framebuffer = newFramebuffer
        framebufferPool = newFramebufferPool
        let newCanvas = AppleCanvas(width: width, height: height, tileCount: 1)
        framebufferCanvas = newCanvas
        initialCoverage = StandardRFBRegionCoverage(width: width, height: height)
        await MainActor.run { canvas = newCanvas }
        await session?.inputController?.update(canvas: newCanvas)
    }

    private func publishFramebuffer() throws {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(
            nil,
            framebufferPool,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw StandardRFBError.framebufferTooLarge
        }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else {
            throw StandardRFBError.framebufferTooLarge
        }
        guard let destination = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            throw StandardRFBError.framebufferTooLarge
        }
        let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let sourceBytesPerRow = framebufferCanvas.width * 4
        framebuffer.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else { return }
            for row in 0..<framebufferCanvas.height {
                destination.advanced(by: row * destinationBytesPerRow).copyMemory(
                    from: sourceBase.advanced(by: row * sourceBytesPerRow),
                    byteCount: sourceBytesPerRow
                )
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        lifecycleLock.withStandardStreamLock { frameCount += 1 }
        let now = ProcessInfo.processInfo.systemUptime
        performance.recordDecodedFrame()
        frames.publish(pixelBuffer, at: AppleVideoFrameStore.fullCanvasIndex, decodedAt: now)
        publishState(.streaming)
    }

    private func beginFramebufferUpdate() {
        framebufferStateLock.withStandardStreamLock {
            framebufferUpdateInProgress = true
        }
    }

    private func abandonFramebufferUpdate() {
        framebufferStateLock.withStandardStreamLock {
            framebufferUpdateInProgress = false
        }
    }

    private func completeFramebufferUpdate(isPublishable: Bool) throws -> TimeInterval {
        try framebufferStateLock.withStandardStreamLock {
            defer { framebufferUpdateInProgress = false }
            guard isPublishable else { return 0 }
            completedFramebufferGeneration &+= 1
            guard shouldPublishLatestFramebufferLocked else { return 0 }
            return try publishLatestFramebufferLocked()
        }
    }

    private var shouldPublishLatestFramebufferLocked: Bool {
        guard completedFramebufferGeneration > publishedFramebufferGeneration else {
            return false
        }
        return !displayDrivenFrameRequestsEnabled
            || displayFrameRequested
            || lifecycleLock.withStandardStreamLock { frameCount == 0 }
    }

    private func publishLatestFramebufferIfIdleLocked() {
        guard !framebufferUpdateInProgress,
              shouldPublishLatestFramebufferLocked else { return }
        do {
            _ = try publishLatestFramebufferLocked()
        } catch {
            Self.logger.error(
                "Standard framebuffer publication failed error=\(error.localizedDescription, privacy: .public)"
            )
            publishState(.failed(error.localizedDescription))
        }
    }

    private func publishLatestFramebufferLocked() throws -> TimeInterval {
        let startedAt = ProcessInfo.processInfo.systemUptime
        try publishFramebuffer()
        let duration = ProcessInfo.processInfo.systemUptime - startedAt
        publishedFramebufferGeneration = completedFramebufferGeneration
        displayFrameRequested = false
        publicationMetrics.frames += 1
        publicationMetrics.duration += duration
        return duration
    }

    private func publishState(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.state = state }
    }

    private func logProcessingMetricsIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - processingMetrics.startedAt
        guard elapsed >= 1, processingMetrics.updates > 0 else { return }
        let values = processingMetrics
        let publications = framebufferStateLock.withStandardStreamLock { () -> PublicationMetrics in
            defer { publicationMetrics = PublicationMetrics() }
            return publicationMetrics
        }
        let updates = Double(values.updates)
        let publishedFrames = Double(max(1, publications.frames))
        let megapixelsPerSecond = Double(values.pixels) / elapsed / 1_000_000
        let sourceMegabitsPerSecond = Double(values.sourceBytes) * 8 / elapsed / 1_000_000
        Self.logger.notice(
            "Standard phases updates=\(values.updates) published=\(publications.frames) rects=\(values.rawRectangles)/\(values.copyRectangles)/\(values.zlibRectangles)/\(values.halftoneRectangles)/\(values.grayscaleRectangles)/\(values.thousandsRectangles)/\(values.hextileRectangles) source=\(sourceMegabitsPerSecond, format: .fixed(precision: 1))Mb/s pixels=\(megapixelsPerSecond, format: .fixed(precision: 1))MP/s inflate=\(values.inflateDuration * 1_000 / updates, format: .fixed(precision: 2))ms apply=\(values.applyDuration * 1_000 / updates, format: .fixed(precision: 2))ms hextile=\(values.hextileDuration * 1_000 / updates, format: .fixed(precision: 2))ms publish=\(publications.duration * 1_000 / publishedFrames, format: .fixed(precision: 2))ms"
        )
        processingMetrics = ProcessingMetrics()
    }

    private static func makeFramebuffer(width: Int, height: Int) throws -> Data {
        let pixelCount = try checkedPixelCount(width: width, height: height)
        let (byteCount, overflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !overflow, byteCount <= maximumFramebufferBytes else {
            throw StandardRFBError.framebufferTooLarge
        }
        return Data(repeating: 0, count: byteCount)
    }

    private static func makePixelBufferPool(
        width: Int,
        height: Int
    ) throws -> CVPixelBufferPool {
        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 3,
        ]
        let pixelBufferAttributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            nil,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let pool else {
            throw StandardRFBError.framebufferTooLarge
        }
        return pool
    }

    private static func checkedPixelCount(width: Int, height: Int) throws -> Int {
        guard width > 0, height > 0 else { throw StandardRFBError.invalidRectangle }
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, count <= maximumFramebufferBytes else {
            throw StandardRFBError.framebufferTooLarge
        }
        return count
    }
}

private extension NSLock {
    func withStandardStreamLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
