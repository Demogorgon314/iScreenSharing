import CoreVideo
import Metal
import OSLog
import QuartzCore

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
    let textureCache: CVMetalTextureCache

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let vertex = library.makeFunction(name: "nv24Vertex"),
              let fragment = library.makeFunction(name: "nv24Fragment") else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }

        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline
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
    private let inFlightGate = AppleMetalInFlightGate()
    var synchronizesPresentation: Bool {
        didSet { configurePresentation() }
    }
    var usesExplicitPresentationTiming = false {
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
        backgroundColor = CGColor.black
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
        performance = source.performance
        latestFrames = source.latestFrames
        lastPresentedSequences = source.lastPresentedSequences
        tileLayouts = source.tileLayouts
        fullCanvasLayout = source.fullCanvasLayout
        renderingBounds = source.renderingBounds
        synchronizesPresentation = source.synchronizesPresentation
        usesExplicitPresentationTiming = false
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
        bounds: CGRect
    ) {
        tileLayouts = layouts
        self.fullCanvasLayout = fullCanvasLayout
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
        self.performance = performance
        usesExplicitPresentationTiming = false
        self.synchronizesPresentation = synchronizesPresentation
        self.showsDeveloperHUD = showsDeveloperHUD
    }

    func prepareForInactivity() {
        latestFrames.removeAll()
        lastPresentedSequences.removeAll()
        tileLayouts.removeAll()
        fullCanvasLayout = AppleVideoCanvasLayout.Tile(container: .zero, content: .zero)
        renderingBounds = .zero
        performance = nil
    }

    @discardableResult
    func present(at targetTimestamp: TimeInterval? = nil) -> Bool {
        guard inFlightGate.begin() else {
            performance?.recordRendererBusy()
            return false
        }
        guard !latestFrames.isEmpty,
              let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let drawable = nextDrawable(),
              encode(into: commandBuffer, drawable: drawable) else {
            inFlightGate.end()
            return false
        }
        commit(
            commandBuffer,
            presenting: drawable,
            submittedAt: ProcessInfo.processInfo.systemUptime,
            targetTimestamp: targetTimestamp
        )
        return true
    }

    private func commit(
        _ commandBuffer: MTLCommandBuffer,
        presenting drawable: CAMetalDrawable,
        submittedAt: TimeInterval,
        targetTimestamp: TimeInterval?
    ) {
        recordPresentation(submittedAt: submittedAt)
        let presentationSubmittedAt = CACurrentMediaTime()
        let performance = performance
        let logger = Self.logger
        drawable.addPresentedHandler { drawable in
            guard drawable.presentedTime > 0 else { return }
            performance?.recordDisplay(
                duration: drawable.presentedTime - presentationSubmittedAt,
                presentedAt: drawable.presentedTime
            )
        }
        if let targetTimestamp,
           targetTimestamp > presentationSubmittedAt {
            commandBuffer.present(drawable, atTime: targetTimestamp)
        } else {
            commandBuffer.present(drawable)
        }
        let inFlightGate = inFlightGate
        commandBuffer.addCompletedHandler { commandBuffer in
            defer { inFlightGate.end() }
            performance?.recordGPU(
                duration: ProcessInfo.processInfo.systemUptime - submittedAt
            )
            if commandBuffer.status == .error {
                logger.error(
                    "Metal frame batch failed: \(commandBuffer.error?.localizedDescription ?? "Unknown error", privacy: .public)"
                )
            }
        }
        commandBuffer.commit()
    }

    private func configurePresentation() {
        displaySyncEnabled = synchronizesPresentation && !usesExplicitPresentationTiming
        presentsWithTransaction = false
    }

    private func configureDeveloperHUD() {
        let mode = showsDeveloperHUD ? "default" : "disabled"
        developerHUDProperties = [
            "mode": mode
        ]
    }

    private func encode(into commandBuffer: MTLCommandBuffer, drawable: CAMetalDrawable) -> Bool {
        guard renderingBounds.width > 0, renderingBounds.height > 0 else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(context.pipeline)
        if let frame = latestFrames[AppleVideoFrameStore.fullCanvasIndex] {
            encode(frame, layout: fullCanvasLayout, using: encoder)
        } else {
            for (tileIndex, frame) in latestFrames.sorted(by: { $0.key < $1.key }) {
                guard tileLayouts.indices.contains(tileIndex) else { continue }
                encode(frame, layout: tileLayouts[tileIndex], using: encoder)
            }
        }
        encoder.endEncoding()
        return true
    }

    private func encode(
        _ frame: AppleVideoFrameStore.Frame,
        layout: AppleVideoCanvasLayout.Tile,
        using encoder: MTLRenderCommandEncoder
    ) {
        let pixelBuffer = frame.pixelBuffer
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
              let vertices = vertices(for: layout),
              let luma = texture(from: pixelBuffer, plane: 0, format: .r8Unorm),
              let chroma = texture(from: pixelBuffer, plane: 1, format: .rg8Unorm) else { return }
        encoder.setVertexBytes(
            vertices,
            length: MemoryLayout<Vertex>.stride * vertices.count,
            index: 0
        )
        encoder.setFragmentTexture(luma, index: 0)
        encoder.setFragmentTexture(chroma, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func recordPresentation(submittedAt: TimeInterval) {
        let changedFrames = latestFrames.filter {
            lastPresentedSequences[$0.key] != $0.value.sequence
        }.map(\.value)
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

    private func vertices(for layout: AppleVideoCanvasLayout.Tile) -> [Vertex]? {
        let container = layout.container
        let content = layout.content
        guard !container.isEmpty, !content.isEmpty else { return nil }

        let left = Float((container.minX - renderingBounds.minX) / renderingBounds.width * 2 - 1)
        let right = Float((container.maxX - renderingBounds.minX) / renderingBounds.width * 2 - 1)
        let bottom = Float((container.minY - renderingBounds.minY) / renderingBounds.height * 2 - 1)
        let top = Float((container.maxY - renderingBounds.minY) / renderingBounds.height * 2 - 1)
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

    private func texture(
        from pixelBuffer: CVPixelBuffer,
        plane: Int,
        format: MTLPixelFormat
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
        return CVMetalTextureGetTexture(image)
    }
}
