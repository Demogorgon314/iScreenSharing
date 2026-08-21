import CoreVideo
import Metal
import OSLog
import QuartzCore

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
    private var latestFrames = [Int: CVPixelBuffer]()
    private var tileLayouts = [AppleVideoCanvasLayout.Tile]()
    private var renderingBounds = CGRect.zero
    var synchronizesPresentation: Bool {
        didSet { configurePresentation() }
    }

    init(context: AppleNV24MetalContext, synchronizesPresentation: Bool = true) {
        self.context = context
        self.synchronizesPresentation = synchronizesPresentation
        super.init()
        device = context.device
        pixelFormat = .bgra8Unorm
        framebufferOnly = true
        backgroundColor = CGColor.black
        configurePresentation()
    }

    override init(layer: Any) {
        guard let source = layer as? AppleNV24MetalLayer else {
            fatalError("AppleNV24MetalLayer can only copy its own presentation layer")
        }
        context = source.context
        latestFrames = source.latestFrames
        tileLayouts = source.tileLayouts
        renderingBounds = source.renderingBounds
        synchronizesPresentation = source.synchronizesPresentation
        super.init(layer: layer)
        configurePresentation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(_ pixelBuffer: CVPixelBuffer, at tileIndex: Int) {
        latestFrames[tileIndex] = pixelBuffer
    }

    func update(layouts: [AppleVideoCanvasLayout.Tile], bounds: CGRect) {
        tileLayouts = layouts
        renderingBounds = bounds
    }

    func present() {
        guard !latestFrames.isEmpty,
              let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let drawable = encode(into: commandBuffer) else { return }
        commandBuffer.present(drawable)
        let logger = Self.logger
        commandBuffer.addCompletedHandler { commandBuffer in
            guard commandBuffer.status == .error else { return }
            logger.error(
                "Metal frame batch failed: \(commandBuffer.error?.localizedDescription ?? "Unknown error", privacy: .public)"
            )
        }
        commandBuffer.commit()
    }

    private func configurePresentation() {
        displaySyncEnabled = synchronizesPresentation
        presentsWithTransaction = false
    }

    override func display() {
        present()
    }

    private func encode(into commandBuffer: MTLCommandBuffer) -> CAMetalDrawable? {
        guard renderingBounds.width > 0, renderingBounds.height > 0 else { return nil }
        let scale = max(contentsScale, 1)
        drawableSize = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
        guard let drawable = nextDrawable() else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setRenderPipelineState(context.pipeline)
        for (tileIndex, frame) in latestFrames.sorted(by: { $0.key < $1.key }) {
            guard tileLayouts.indices.contains(tileIndex),
                  CVPixelBufferGetPlaneCount(frame) >= 2,
                  let vertices = vertices(for: tileLayouts[tileIndex]),
                  let luma = texture(from: frame, plane: 0, format: .r8Unorm),
                  let chroma = texture(from: frame, plane: 1, format: .rg8Unorm) else { continue }
            encoder.setVertexBytes(
                vertices,
                length: MemoryLayout<Vertex>.stride * vertices.count,
                index: 0
            )
            encoder.setFragmentTexture(luma, index: 0)
            encoder.setFragmentTexture(chroma, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        return drawable
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
