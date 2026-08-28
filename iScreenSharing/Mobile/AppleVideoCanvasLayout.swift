import CoreGraphics

enum AppleVideoCanvasLayout {
    struct Tile: Equatable {
        let container: CGRect
        let content: CGRect
    }

    static func fullCanvas(canvas: AppleCanvas, bounds: CGRect) -> Tile {
        guard canvas.width > 0, canvas.height > 0, !bounds.isEmpty else {
            return Tile(container: .zero, content: .zero)
        }
        let size = fittedSize(canvas: canvas, bounds: bounds)
        let container = CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        return Tile(
            container: container,
            content: CGRect(origin: .zero, size: size)
        )
    }

    static func tiles(canvas: AppleCanvas, bounds: CGRect) -> [Tile] {
        guard canvas.tileCount > 0 else { return [] }
        let full = fullCanvas(canvas: canvas, bounds: bounds)
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
                y: full.container.maxY - outputSlotHeight * CGFloat(index + 1),
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

    private static func fittedSize(canvas: AppleCanvas, bounds: CGRect) -> CGSize {
        let scale = min(
            bounds.width / CGFloat(canvas.width),
            bounds.height / CGFloat(canvas.height)
        )
        return CGSize(width: CGFloat(canvas.width) * scale, height: CGFloat(canvas.height) * scale)
    }
}
