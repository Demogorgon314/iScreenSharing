import CoreGraphics
import struct ScreenSharingProtocol.AppleCanvas

enum AppleVideoCanvasLayout {
    struct Tile: Equatable {
        let container: CGRect
        let content: CGRect
    }

    static func fullCanvas(canvas: AppleCanvas, bounds: CGRect, viewport: MobileCanvasViewport = .init()) -> Tile {
        guard canvas.width > 0, canvas.height > 0, !bounds.isEmpty else {
            return Tile(container: .zero, content: .zero)
        }
        let fitBounds = viewport.fittingBounds(in: bounds)
        let size = fittedSize(canvas: canvas, bounds: fitBounds)
        let originY = fitBounds.height > fitBounds.width
            ? fitBounds.minY
            : fitBounds.midY - size.height / 2
        let container = CGRect(
            x: fitBounds.midX - size.width / 2,
            y: originY,
            width: size.width,
            height: size.height
        )
        let visible = viewport.frame(base: container, bounds: bounds)
        return Tile(container: visible, content: CGRect(origin: .zero, size: visible.size))
    }

    static func tiles(canvas: AppleCanvas, bounds: CGRect, viewport: MobileCanvasViewport = .init()) -> [Tile] {
        guard canvas.tileCount > 0 else { return [] }
        let full = fullCanvas(canvas: canvas, bounds: bounds, viewport: viewport)
        guard !full.container.isEmpty else { return [] }
        let slotHeight = CGFloat(canvas.height) / CGFloat(canvas.tileCount)
        let outputSlotHeight = full.container.height / CGFloat(canvas.tileCount)
        return (0..<canvas.tileCount).map { index in
            let height = index == canvas.tileCount - 1
                ? CGFloat(canvas.height) - slotHeight * CGFloat(index)
                : slotHeight
            let outputHeight = index == canvas.tileCount - 1
                ? full.container.height - outputSlotHeight * CGFloat(index)
                : outputSlotHeight
            let container = CGRect(
                x: full.container.minX,
                y: full.container.minY + outputSlotHeight * CGFloat(index),
                width: full.container.width,
                height: outputHeight
            )
            return Tile(
                container: container,
                content: CGRect(
                    x: 0,
                    y: 0,
                    width: full.container.width,
                    height: height * full.container.width / CGFloat(canvas.width)
                )
            )
        }
    }

    static func remotePoint(location: CGPoint, canvas: AppleCanvas, bounds: CGRect) -> (x: Int, y: Int)? {
        let layout = fullCanvas(canvas: canvas, bounds: bounds).container
        guard layout.contains(location), !layout.isEmpty else { return nil }
        let x = Int((location.x - layout.minX) / layout.width * CGFloat(canvas.width))
        let y = Int((location.y - layout.minY) / layout.height * CGFloat(canvas.height))
        return (
            min(canvas.width - 1, max(0, x)),
            min(canvas.height - 1, max(0, y))
        )
    }

    static func localPoint(
        remoteX: Int,
        remoteY: Int,
        canvas: AppleCanvas,
        bounds: CGRect,
        viewport: MobileCanvasViewport = .init()
    ) -> CGPoint? {
        let layout = fullCanvas(canvas: canvas, bounds: bounds, viewport: viewport).container
        guard !layout.isEmpty, canvas.width > 0, canvas.height > 0 else { return nil }
        let x = min(canvas.width - 1, max(0, remoteX))
        let y = min(canvas.height - 1, max(0, remoteY))
        return CGPoint(
            x: layout.minX + CGFloat(x) / CGFloat(canvas.width) * layout.width,
            y: layout.minY + CGFloat(y) / CGFloat(canvas.height) * layout.height
        )
    }

    static func nativeTileContainer(
        logicalStart: CGFloat,
        validHeight: CGFloat,
        canvasSize: CGSize,
        width: CGFloat
    ) -> CGRect {
        CGRect(
            x: 0,
            y: logicalStart,
            width: min(width, canvasSize.width),
            height: validHeight
        )
    }

    private static func fittedSize(canvas: AppleCanvas, bounds: CGRect) -> CGSize {
        let scale = min(
            bounds.width / CGFloat(canvas.width),
            bounds.height / CGFloat(canvas.height)
        )
        return CGSize(width: CGFloat(canvas.width) * scale, height: CGFloat(canvas.height) * scale)
    }
}
