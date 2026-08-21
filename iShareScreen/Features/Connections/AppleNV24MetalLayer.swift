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

    vertex VertexOutput nv24Vertex(uint index [[vertex_id]]) {
        const float2 positions[] = {
            float2(-1.0, -1.0),
            float2( 3.0, -1.0),
            float2(-1.0,  3.0)
        };
        const float2 coordinates[] = {
            float2(0.0, 1.0),
            float2(2.0, 1.0),
            float2(0.0, -1.0)
        };
        return { float4(positions[index], 0.0, 1.0), coordinates[index] };
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
    private static let logger = Logger(subsystem: "com.wangkai.iShareScreen", category: "VideoRenderer")
    private let context: AppleNV24MetalContext
    private var latestFrame: CVPixelBuffer?
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
        latestFrame = source.latestFrame
        synchronizesPresentation = source.synchronizesPresentation
        super.init(layer: layer)
        configurePresentation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(_ pixelBuffer: CVPixelBuffer) {
        latestFrame = pixelBuffer
    }

    static func present(_ layers: [AppleNV24MetalLayer]) {
        guard let first = layers.first,
              layers.allSatisfy({ $0.latestFrame != nil }),
              layers.dropFirst().allSatisfy({ $0.context === first.context }),
              let commandBuffer = first.context.commandQueue.makeCommandBuffer() else { return }
        var drawables = [CAMetalDrawable]()
        for layer in layers {
            guard let drawable = layer.encode(into: commandBuffer) else { return }
            drawables.append(drawable)
        }
        drawables.forEach { commandBuffer.present($0) }
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
        Self.present([self])
    }

    private func encode(into commandBuffer: MTLCommandBuffer) -> CAMetalDrawable? {
        guard let frame = latestFrame,
              CVPixelBufferGetPlaneCount(frame) >= 2 else { return nil }
        let scale = max(contentsScale, 1)
        drawableSize = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
        guard let drawable = nextDrawable(),
              let luma = texture(
                  from: frame,
                  plane: 0,
                  format: .r8Unorm
              ),
              let chroma = texture(
                  from: frame,
                  plane: 1,
                  format: .rg8Unorm
              ) else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setRenderPipelineState(context.pipeline)
        encoder.setFragmentTexture(luma, index: 0)
        encoder.setFragmentTexture(chroma, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return drawable
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
