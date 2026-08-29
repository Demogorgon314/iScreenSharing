import CoreVideo
import Metal
import OSLog
import QuartzCore

// The completion queue only releases these immutable references; it never
// accesses image contents. Core Video retention prevents buffer-pool reuse.
private struct AppleMetalTextureReferences: @unchecked Sendable {
    let images: [CVMetalTexture]
}

private final class AppleMetalInFlightGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isInFlight = false

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isInFlight else { return false }
        isInFlight = true
        return true
    }

    func end() {
        lock.lock()
        isInFlight = false
        lock.unlock()
    }
}

@MainActor
final class AppleNV24MetalContext {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let rgbaPipeline: MTLRenderPipelineState
    let textureCache: CVMetalTextureCache

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let vertex = library.makeFunction(name: "nv24Vertex"),
              let fragment = library.makeFunction(name: "nv24Fragment"),
              let rgbaFragment = library.makeFunction(name: "rgbaFragment") else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        descriptor.fragmentFunction = rgbaFragment
        guard let rgbaPipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }

        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.rgbaPipeline = rgbaPipeline
        textureCache = cache
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOutput {
        float4 position [[position]];
        float2 textureCoordinate;
    };

    struct VertexInput {
        float2 position;
        float2 textureCoordinate;
    };

    vertex VertexOutput nv24Vertex(
        uint index [[vertex_id]],
        constant VertexInput *vertices [[buffer(0)]]) {
        return {
            float4(vertices[index].position, 0.0, 1.0),
            vertices[index].textureCoordinate
        };
    }

    fragment float4 nv24Fragment(
        VertexOutput input [[stage_in]],
        texture2d<float> luma [[texture(0)]],
        texture2d<float> chroma [[texture(1)]]) {
        constexpr sampler textureSampler(address::clamp_to_edge, filter::linear);
        const float y = luma.sample(textureSampler, input.textureCoordinate).r;
        const float2 uv = chroma.sample(textureSampler, input.textureCoordinate).rg - 0.5;
        const float3 rgb = float3(
            y + 1.5748 * uv.y,
            y - 0.187324 * uv.x - 0.468124 * uv.y,
            y + 1.8556 * uv.x
        );
        return float4(rgb, 1.0);
    }

    fragment float4 rgbaFragment(
        VertexOutput input [[stage_in]],
        texture2d<float> texture [[texture(0)]]) {
        constexpr sampler textureSampler(address::clamp_to_edge, filter::linear);
        return texture.sample(textureSampler, input.textureCoordinate);
    }
    """
}

@MainActor
final class AppleNV24MetalLayer: CAMetalLayer {
    private struct Vertex {
        let position: SIMD2<Float>
        let textureCoordinate: SIMD2<Float>
    }

    private static let logger = Logger(subsystem: "com.wangkai.iShareScreen", category: "VideoRenderer")
    private let context: AppleNV24MetalContext
    private var performance: AppleVideoPerformanceMonitor?
    private var latestFrames = AppleVideoFrameStore.FrameBatch()
    private var lastPresentedSequences = [Int: UInt64]()
    private var tileLayouts = [AppleVideoCanvasLayout.Tile]()
    private var fullCanvasLayout = AppleVideoCanvasLayout.Tile(container: .zero, content: .zero)
    private var renderingBounds = CGRect.zero
    private var canvasSize = CGSize.zero
    private var compositedCanvas: MTLTexture?
    private let inFlightGate = AppleMetalInFlightGate()
    var connectionTiming: ConnectionStartupTrace?
    var displayIndex: Int = 0
    var didPresentFrame: (@Sendable () -> Void)?
    var synchronizesPresentation: Bool {
        didSet { configurePresentation() }
    }
    var showsDeveloperHUD: Bool {
        didSet { configureDeveloperHUD() }
    }

    init(
        context: AppleNV24MetalContext,
        synchronizesPresentation: Bool = true,
        showsDeveloperHUD: Bool = false,
        performance: AppleVideoPerformanceMonitor? = nil
    ) {
        self.context = context
        self.synchronizesPresentation = synchronizesPresentation
        self.showsDeveloperHUD = showsDeveloperHUD
        self.performance = performance
        super.init()
        device = context.device
        pixelFormat = .bgra8Unorm
        framebufferOnly = true
        backgroundColor = CGColor(gray: 0, alpha: 1)
        maximumDrawableCount = 2
        allowsNextDrawableTimeout = true
        configurePresentation()
        configureDeveloperHUD()
    }

    override init(layer: Any) {
        guard let source = layer as? AppleNV24MetalLayer else {
            fatalError("AppleNV24MetalLayer can only copy its own presentation layer")
        }
        context = source.context
        connectionTiming = source.connectionTiming
        displayIndex = source.displayIndex
        performance = source.performance
        latestFrames = source.latestFrames
        lastPresentedSequences = source.lastPresentedSequences
        tileLayouts = source.tileLayouts
        fullCanvasLayout = source.fullCanvasLayout
        renderingBounds = source.renderingBounds
        canvasSize = source.canvasSize
        compositedCanvas = source.compositedCanvas
        synchronizesPresentation = source.synchronizesPresentation
        showsDeveloperHUD = false
        super.init(layer: layer)
        configurePresentation()
        configureDeveloperHUD()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(_ frame: AppleVideoFrameStore.Frame, at tileIndex: Int) {
        if tileIndex == AppleVideoFrameStore.fullCanvasIndex {
            latestFrames = [tileIndex: frame]
            lastPresentedSequences = lastPresentedSequences.filter { $0.key == tileIndex }
        } else {
            latestFrames.removeValue(forKey: AppleVideoFrameStore.fullCanvasIndex)
            lastPresentedSequences.removeValue(forKey: AppleVideoFrameStore.fullCanvasIndex)
            latestFrames[tileIndex] = frame
        }
    }

    func update(
        layouts: [AppleVideoCanvasLayout.Tile],
        fullCanvasLayout: AppleVideoCanvasLayout.Tile,
        canvasSize: CGSize,
        bounds: CGRect
    ) {
        tileLayouts = layouts
        self.fullCanvasLayout = fullCanvasLayout
        if self.canvasSize != canvasSize {
            self.canvasSize = canvasSize
            compositedCanvas = nil
        }
        renderingBounds = bounds
        updateDrawableSize()
    }

    func prepareForReuse(
        synchronizesPresentation: Bool,
        showsDeveloperHUD: Bool,
        performance: AppleVideoPerformanceMonitor?
    ) {
        latestFrames.removeAll()
        lastPresentedSequences.removeAll()
        tileLayouts.removeAll()
        fullCanvasLayout = AppleVideoCanvasLayout.Tile(container: .zero, content: .zero)
        renderingBounds = .zero
        canvasSize = .zero
        compositedCanvas = nil
        self.performance = performance
        self.synchronizesPresentation = synchronizesPresentation
        self.showsDeveloperHUD = showsDeveloperHUD
    }

    func prepareForInactivity() {
        latestFrames.removeAll()
        lastPresentedSequences.removeAll()
        tileLayouts.removeAll()
        fullCanvasLayout = AppleVideoCanvasLayout.Tile(container: .zero, content: .zero)
        renderingBounds = .zero
        canvasSize = .zero
        compositedCanvas = nil
        performance = nil
        connectionTiming = nil
    }

    @discardableResult
    func present(
        targetTimestamp: TimeInterval? = nil,
        displayPeriod: TimeInterval? = nil,
        isDisplayLinkTriggered: Bool = false
    ) -> Bool {
        let renderCallStartedAt = CACurrentMediaTime()
        guard inFlightGate.begin() else {
            performance?.recordRendererBusy()
            return false
        }
        guard !latestFrames.isEmpty,
              let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            inFlightGate.end()
            return false
        }
        let drawableWaitStartedAt = CACurrentMediaTime()
        guard let drawable = nextDrawable() else {
            inFlightGate.end()
            return false
        }
        let drawableAcquiredAt = CACurrentMediaTime()
        let encodeStartedAt = drawableAcquiredAt
        guard encode(into: commandBuffer, drawable: drawable) else {
            inFlightGate.end()
            return false
        }
        let encodeEndedAt = CACurrentMediaTime()
        let changedFrames = changedFrames()
        let batchID = performance?.beginRenderBatch(
            frameKeys: changedFrames.map(\.sequence),
            drawableWaitStartedAt: drawableWaitStartedAt,
            drawableAcquiredAt: drawableAcquiredAt,
            encodeStartedAt: encodeStartedAt,
            encodeEndedAt: encodeEndedAt,
            targetTimestamp: targetTimestamp,
            displayPeriod: displayPeriod,
            isDisplayLinkTriggered: isDisplayLinkTriggered
        )
        commit(
            commandBuffer,
            presenting: drawable,
            changedFrames: changedFrames,
            submittedAt: encodeEndedAt,
            batchID: batchID
        )
        performance?.recordRenderCall(duration: CACurrentMediaTime() - renderCallStartedAt)
        return true
    }

    func snapshot() -> CGImage? {
        let width = Int(drawableSize.width)
        let height = Int(drawableSize.height)
        guard !latestFrames.isEmpty, width > 0, height > 0,
              let commandBuffer = context.commandQueue.makeCommandBuffer() else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        guard let texture = context.device.makeTexture(descriptor: descriptor),
              encode(into: commandBuffer, texture: texture) else { return nil }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }

        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.getBytes(
                baseAddress,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        let bitmapInfo: CGBitmapInfo = [
            .byteOrder32Little,
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue),
        ]
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func commit(
        _ commandBuffer: MTLCommandBuffer,
        presenting drawable: CAMetalDrawable,
        changedFrames: [AppleVideoFrameStore.Frame],
        submittedAt: TimeInterval,
        batchID: UInt64?
    ) {
        recordPresentation(changedFrames, submittedAt: submittedAt)
        let presentationSubmittedAt = CACurrentMediaTime()
        let performance = performance
        let logger = Self.logger
#if os(macOS)
        let didPresentFrame = didPresentFrame
        // Capture this session's trace now; the retained layer can be reused
        // before Metal delivers the old drawable's callback.
        let timing = connectionTiming
        let displayIndex = displayIndex
        drawable.addPresentedHandler { drawable in
            guard drawable.presentedTime > 0 else { return }
            timing?.record(
                .firstPresented, index: displayIndex,
                since: .init(.firstFramePublished, index: displayIndex),
                at: drawable.presentedTime
            )
            performance?.recordDisplay(
                duration: drawable.presentedTime - presentationSubmittedAt,
                presentedAt: drawable.presentedTime
            )
            if let batchID {
                performance?.recordRenderBatchPresented(batchID, at: drawable.presentedTime)
            }
            didPresentFrame?()
        }
#endif
        commandBuffer.present(drawable)
        if let batchID {
            commandBuffer.addScheduledHandler { _ in
                performance?.recordRenderBatchScheduled(batchID, at: CACurrentMediaTime())
            }
        }
        let inFlightGate = inFlightGate
        commandBuffer.addCompletedHandler { commandBuffer in
            defer { inFlightGate.end() }
#if !os(macOS)
            let completedAt = CACurrentMediaTime()
            performance?.recordDisplay(
                duration: completedAt - presentationSubmittedAt,
                presentedAt: completedAt
            )
            if let batchID {
                performance?.recordRenderBatchPresented(batchID, at: completedAt)
            }
#endif
            performance?.recordGPU(
                duration: CACurrentMediaTime() - submittedAt
            )
            if let batchID {
                let hasValidGPUTimestamps = commandBuffer.gpuStartTime > 0
                    && commandBuffer.gpuEndTime >= commandBuffer.gpuStartTime
                performance?.recordRenderBatchCompleted(
                    batchID,
                    gpuStart: hasValidGPUTimestamps ? commandBuffer.gpuStartTime : nil,
                    gpuEnd: hasValidGPUTimestamps ? commandBuffer.gpuEndTime : nil
                )
            }
            if commandBuffer.status == .error {
                logger.error(
                    "Metal frame batch failed: \(commandBuffer.error?.localizedDescription ?? "Unknown error", privacy: .public)"
                )
            }
        }
        let commitAt = CACurrentMediaTime()
        commandBuffer.commit()
        if let batchID {
            performance?.recordRenderBatchCommitted(batchID, at: commitAt)
        }
    }

    private func configurePresentation() {
#if os(macOS)
        displaySyncEnabled = synchronizesPresentation
#endif
        presentsWithTransaction = false
    }

    private func configureDeveloperHUD() {
#if os(macOS)
        let mode = showsDeveloperHUD ? "default" : "disabled"
        developerHUDProperties = [
            "mode": mode
        ]
#endif
    }

    private func encode(into commandBuffer: MTLCommandBuffer, drawable: CAMetalDrawable) -> Bool {
        encode(into: commandBuffer, texture: drawable.texture)
    }

    /// Encodes the current frames and keeps their Core Video images in use
    /// until the command buffer completes, independently of later frame updates.
    func encode(into commandBuffer: MTLCommandBuffer, texture: MTLTexture) -> Bool {
        var images = [CVMetalTexture]()
        defer {
            if !images.isEmpty {
                let references = AppleMetalTextureReferences(images: images)
                commandBuffer.addCompletedHandler { _ in
                    withExtendedLifetime(references) {}
                }
            }
        }
        guard renderingBounds.width > 0, renderingBounds.height > 0 else { return false }
        if let frame = latestFrames[AppleVideoFrameStore.fullCanvasIndex] {
            if CVPixelBufferGetPixelFormatType(frame.pixelBuffer) == kCVPixelFormatType_32BGRA,
               let source = bgraTexture(from: frame.pixelBuffer, retaining: &images) {
                return encodeRGBA(
                    source,
                    layout: fullCanvasLayout,
                    into: texture,
                    commandBuffer: commandBuffer
                )
            }
            return encodeNV24Frames(
                [(frame, fullCanvasLayout)],
                into: texture,
                bounds: renderingBounds,
                commandBuffer: commandBuffer,
                retaining: &images
            )
        }
        guard let compositedCanvas = canvasTexture(),
              encodeNV24Frames(
                  nativeTileFrames(),
                  into: compositedCanvas,
                  bounds: CGRect(origin: .zero, size: canvasSize),
                  commandBuffer: commandBuffer,
                  retaining: &images
              ) else { return false }
        return encodeRGBA(
            compositedCanvas,
            layout: fullCanvasLayout,
            into: texture,
            commandBuffer: commandBuffer
        )
    }

    private func encodeNV24Frames(
        _ frames: [(AppleVideoFrameStore.Frame, AppleVideoCanvasLayout.Tile)],
        into texture: MTLTexture,
        bounds: CGRect,
        commandBuffer: MTLCommandBuffer,
        retaining images: inout [CVMetalTexture]
    ) -> Bool {
        guard !frames.isEmpty else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(context.pipeline)
        for (frame, layout) in frames {
            encode(frame, layout: layout, bounds: bounds, using: encoder, retaining: &images)
        }
        encoder.endEncoding()
        return true
    }

    private func encodeRGBA(
        _ source: MTLTexture,
        layout: AppleVideoCanvasLayout.Tile,
        into texture: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard let vertices = vertices(for: layout, bounds: renderingBounds) else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(context.rgbaPipeline)
        encoder.setVertexBytes(
            vertices,
            length: MemoryLayout<Vertex>.stride * vertices.count,
            index: 0
        )
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        return true
    }

    private func encode(
        _ frame: AppleVideoFrameStore.Frame,
        layout: AppleVideoCanvasLayout.Tile,
        bounds: CGRect,
        using encoder: MTLRenderCommandEncoder,
        retaining images: inout [CVMetalTexture]
    ) {
        let pixelBuffer = frame.pixelBuffer
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
              let vertices = vertices(for: layout, bounds: bounds),
              let luma = texture(from: pixelBuffer, plane: 0, format: .r8Unorm, retaining: &images),
              let chroma = texture(from: pixelBuffer, plane: 1, format: .rg8Unorm, retaining: &images) else { return }
        encoder.setVertexBytes(
            vertices,
            length: MemoryLayout<Vertex>.stride * vertices.count,
            index: 0
        )
        encoder.setFragmentTexture(luma, index: 0)
        encoder.setFragmentTexture(chroma, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func changedFrames() -> [AppleVideoFrameStore.Frame] {
        latestFrames.filter {
            lastPresentedSequences[$0.key] != $0.value.sequence
        }.map(\.value)
    }

    private func recordPresentation(
        _ changedFrames: [AppleVideoFrameStore.Frame],
        submittedAt: TimeInterval
    ) {
        guard !changedFrames.isEmpty else { return }

        let averageDecodedAt = changedFrames.map(\.decodedAt).reduce(0, +) / Double(changedFrames.count)
        let decodedTimes = changedFrames.map(\.decodedAt)
        let tileSkew = (decodedTimes.max() ?? submittedAt) - (decodedTimes.min() ?? submittedAt)
        let decodingOrders = changedFrames.compactMap(\.decodingOrderNumber)
        var decodingOrderSpan = 0
        for lhs in decodingOrders {
            for rhs in decodingOrders {
                decodingOrderSpan = max(
                    decodingOrderSpan,
                    Int(min(lhs &- rhs, rhs &- lhs))
                )
            }
        }
        performance?.recordPresentation(
            latency: submittedAt - averageDecodedAt,
            tileSkew: tileSkew,
            decodingOrderSpan: decodingOrderSpan
        )
        for (tileIndex, frame) in latestFrames {
            lastPresentedSequences[tileIndex] = frame.sequence
        }
    }

    private func updateDrawableSize() {
        let scale = max(contentsScale, 1)
        let nextDrawableSize = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
        guard drawableSize != nextDrawableSize else { return }
        drawableSize = nextDrawableSize
    }

    private func vertices(
        for layout: AppleVideoCanvasLayout.Tile,
        bounds: CGRect
    ) -> [Vertex]? {
        let container = layout.container
        let content = layout.content
        guard !container.isEmpty, !content.isEmpty,
              bounds.width > 0, bounds.height > 0 else { return nil }

        let left = Float((container.minX - bounds.minX) / bounds.width * 2 - 1)
        let right = Float((container.maxX - bounds.minX) / bounds.width * 2 - 1)
#if os(iOS)
        let bottom = Float(1 - (container.maxY - bounds.minY) / bounds.height * 2)
        let top = Float(1 - (container.minY - bounds.minY) / bounds.height * 2)
#else
        let bottom = Float((container.minY - bounds.minY) / bounds.height * 2 - 1)
        let top = Float((container.maxY - bounds.minY) / bounds.height * 2 - 1)
#endif
        let u0 = Float((0 - content.minX) / content.width)
        let u1 = Float((container.width - content.minX) / content.width)
        let vBottom = Float(1 - (0 - content.minY) / content.height)
        let vTop = Float(1 - (container.height - content.minY) / content.height)
        return [
            Vertex(position: SIMD2(left, bottom), textureCoordinate: SIMD2(u0, vBottom)),
            Vertex(position: SIMD2(right, bottom), textureCoordinate: SIMD2(u1, vBottom)),
            Vertex(position: SIMD2(left, top), textureCoordinate: SIMD2(u0, vTop)),
            Vertex(position: SIMD2(right, top), textureCoordinate: SIMD2(u1, vTop)),
        ]
    }

    private func canvasTexture() -> MTLTexture? {
        let width = Int(canvasSize.width)
        let height = Int(canvasSize.height)
        guard width > 0, height > 0 else { return nil }
        if let compositedCanvas,
           compositedCanvas.width == width,
           compositedCanvas.height == height {
            return compositedCanvas
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        compositedCanvas = context.device.makeTexture(descriptor: descriptor)
        return compositedCanvas
    }

    private func nativeTileFrames()
        -> [(AppleVideoFrameStore.Frame, AppleVideoCanvasLayout.Tile)] {
        return latestFrames.sorted(by: { $0.key < $1.key }).compactMap { tileIndex, frame in
            guard tileLayouts.indices.contains(tileIndex) else { return nil }
            let pixelBuffer = frame.pixelBuffer
            let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
            let slotHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
            let fallbackHeight = ceil(canvasSize.height / CGFloat(max(1, tileLayouts.count)))
            let logicalStart = (0..<tileIndex).reduce(CGFloat.zero) { result, index in
                guard let preceding = latestFrames[index]?.pixelBuffer else {
                    return result + fallbackHeight
                }
                return result + CGFloat(CVPixelBufferGetHeight(preceding))
            }
            let validHeight = min(slotHeight, max(0, canvasSize.height - logicalStart))
            guard width > 0, validHeight > 0 else { return nil }
#if os(iOS)
            let container = AppleVideoCanvasLayout.nativeTileContainer(
                logicalStart: logicalStart,
                validHeight: validHeight,
                canvasSize: canvasSize,
                width: width
            )
#else
            let container = CGRect(
                x: 0,
                y: canvasSize.height - logicalStart - validHeight,
                width: min(width, canvasSize.width),
                height: validHeight
            )
#endif
            let content = CGRect(
                x: 0,
                y: validHeight - slotHeight,
                width: width,
                height: slotHeight
            )
            return (frame, AppleVideoCanvasLayout.Tile(container: container, content: content))
        }
    }

    private func texture(
        from pixelBuffer: CVPixelBuffer,
        plane: Int,
        format: MTLPixelFormat,
        retaining images: inout [CVMetalTexture]
    ) -> MTLTexture? {
        var image: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            context.textureCache,
            pixelBuffer,
            nil,
            format,
            CVPixelBufferGetWidthOfPlane(pixelBuffer, plane),
            CVPixelBufferGetHeightOfPlane(pixelBuffer, plane),
            plane,
            &image
        )
        guard status == kCVReturnSuccess, let image else { return nil }
        images.append(image)
        return CVMetalTextureGetTexture(image)
    }

    private func bgraTexture(
        from pixelBuffer: CVPixelBuffer,
        retaining images: inout [CVMetalTexture]
    ) -> MTLTexture? {
        var image: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            context.textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            CVPixelBufferGetWidth(pixelBuffer),
            CVPixelBufferGetHeight(pixelBuffer),
            0,
            &image
        )
        guard status == kCVReturnSuccess, let image else { return nil }
        images.append(image)
        return CVMetalTextureGetTexture(image)
    }
}
