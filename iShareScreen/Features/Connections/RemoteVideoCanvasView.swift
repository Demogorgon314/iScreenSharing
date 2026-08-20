import AVFoundation
import SwiftUI

struct RemoteVideoCanvasView: NSViewRepresentable {
    let canvas: AppleCanvas
    let frames: AppleVideoFrameStore
    let scalesToFit: Bool

    func makeNSView(context: Context) -> RemoteVideoCanvasNSView {
        RemoteVideoCanvasNSView(canvas: canvas, frames: frames, scalesToFit: scalesToFit)
    }

    func updateNSView(_ view: RemoteVideoCanvasNSView, context: Context) {
        view.scalesToFit = scalesToFit
    }
}

final class RemoteVideoCanvasNSView: NSView {
    var scalesToFit: Bool {
        didSet { needsLayout = true }
    }

    private let canvas: AppleCanvas
    private let frames: AppleVideoFrameStore
    private let tileContainers: [CALayer]
    private let displayLayers: [AVSampleBufferDisplayLayer]
    private var observer: UUID?
    private var decodedTileHeight: CGFloat?

    init(canvas: AppleCanvas, frames: AppleVideoFrameStore, scalesToFit: Bool) {
        self.canvas = canvas
        self.frames = frames
        self.scalesToFit = scalesToFit
        tileContainers = (0..<canvas.tileCount).map { _ in CALayer() }
        displayLayers = (0..<canvas.tileCount).map { _ in AVSampleBufferDisplayLayer() }
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        for (container, displayLayer) in zip(tileContainers, displayLayers) {
            container.masksToBounds = true
            displayLayer.videoGravity = .resize
            container.addSublayer(displayLayer)
            layer?.addSublayer(container)
        }
        observer = frames.addObserver { [weak self] tileIndex, frame in
            self?.display(frame, at: tileIndex)
        }
        for tileIndex in displayLayers.indices {
            if let frame = frames.frame(at: tileIndex) { display(frame, at: tileIndex) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let observer { frames.removeObserver(observer) }
    }

    override func layout() {
        super.layout()
        let slotHeight = decodedTileHeight ?? ceil(CGFloat(canvas.height) / CGFloat(canvas.tileCount))
        let layouts = AppleVideoCanvasLayout.tiles(
            canvas: canvas,
            bounds: bounds,
            slotHeight: slotHeight,
            scalesToFit: scalesToFit
        )
        for (index, layout) in layouts.enumerated() {
            tileContainers[index].frame = layout.container
            displayLayers[index].frame = layout.content
            tileContainers[index].isHidden = layout.container.isEmpty
        }
    }

    private func display(_ pixelBuffer: CVPixelBuffer, at tileIndex: Int) {
        precondition(Thread.isMainThread)
        guard displayLayers.indices.contains(tileIndex) else { return }
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        if decodedTileHeight != height {
            decodedTileHeight = height
            needsLayout = true
        }

        let displayLayer = displayLayers[tileIndex]
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
        guard renderer.isReadyForMoreMediaData,
              let sampleBuffer = Self.sampleBuffer(for: pixelBuffer) else { return }
        renderer.enqueue(sampleBuffer)
    }

    private static func sampleBuffer(for pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .invalid,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }
        CMSetAttachment(
            sampleBuffer,
            key: kCMSampleAttachmentKey_DisplayImmediately,
            value: kCFBooleanTrue,
            attachmentMode: kCMAttachmentMode_ShouldPropagate
        )
        return sampleBuffer
    }
}

enum AppleVideoCanvasLayout {
    struct Tile: Equatable {
        let container: CGRect
        let content: CGRect
    }

    static func tiles(
        canvas: AppleCanvas,
        bounds: CGRect,
        slotHeight: CGFloat,
        scalesToFit: Bool
    ) -> [Tile] {
        guard canvas.tileCount > 0, canvas.width > 0, canvas.height > 0, slotHeight > 0 else {
            return []
        }
        let canvasSize = CGSize(width: canvas.width, height: canvas.height)
        let scale = scalesToFit
            ? min(bounds.width / canvasSize.width, bounds.height / canvasSize.height)
            : 1
        let outputSize = CGSize(width: canvasSize.width * scale, height: canvasSize.height * scale)
        let canvasRect = CGRect(
            x: bounds.midX - outputSize.width / 2,
            y: bounds.midY - outputSize.height / 2,
            width: outputSize.width,
            height: outputSize.height
        )
        return (0..<canvas.tileCount).map { tileIndex in
            let pixelOrigin = CGFloat(tileIndex) * slotHeight
            let visibleHeight = min(slotHeight, max(0, canvasSize.height - pixelOrigin))
            guard visibleHeight > 0 else { return Tile(container: .zero, content: .zero) }
            let container = CGRect(
                x: canvasRect.minX,
                y: canvasRect.maxY - (pixelOrigin + visibleHeight) * scale,
                width: canvasRect.width,
                height: visibleHeight * scale
            )
            let content = CGRect(
                x: 0,
                y: -(slotHeight - visibleHeight) * scale,
                width: container.width,
                height: slotHeight * scale
            )
            return Tile(container: container, content: content)
        }
    }
}
