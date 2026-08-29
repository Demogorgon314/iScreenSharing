import CoreGraphics

struct MobileRemotePointerState {
    struct Point: Equatable {
        let x: Int
        let y: Int
    }

    private(set) var point: Point?
    private var fractionalX: CGFloat = 0
    private var fractionalY: CGFloat = 0

    mutating func currentPoint(canvas: AppleCanvas) -> Point {
        let next = point.map { clamped($0, canvas: canvas) }
            ?? Point(x: canvas.width / 2, y: canvas.height / 2)
        point = next
        return next
    }

    mutating func move(
        by localTranslation: CGPoint,
        canvas: AppleCanvas,
        bounds: CGRect
    ) -> Point {
        let current = currentPoint(canvas: canvas)
        let layout = AppleVideoCanvasLayout.fullCanvas(canvas: canvas, bounds: bounds).container
        guard !layout.isEmpty else { return current }

        fractionalX += localTranslation.x / layout.width * CGFloat(canvas.width)
        fractionalY += localTranslation.y / layout.height * CGFloat(canvas.height)
        let deltaX = Int(fractionalX.rounded(.towardZero))
        let deltaY = Int(fractionalY.rounded(.towardZero))
        fractionalX -= CGFloat(deltaX)
        fractionalY -= CGFloat(deltaY)

        let proposed = Point(x: current.x + deltaX, y: current.y + deltaY)
        let next = clamped(proposed, canvas: canvas)
        if next.x != proposed.x { fractionalX = 0 }
        if next.y != proposed.y { fractionalY = 0 }
        point = next
        return next
    }

    mutating func setAbsolute(
        localPoint: CGPoint,
        canvas: AppleCanvas,
        bounds: CGRect
    ) -> Point? {
        guard let mapped = AppleVideoCanvasLayout.remotePoint(
            location: localPoint,
            canvas: canvas,
            bounds: bounds
        ) else { return nil }
        let next = Point(x: mapped.x, y: mapped.y)
        point = next
        fractionalX = 0
        fractionalY = 0
        return next
    }

    private func clamped(_ point: Point, canvas: AppleCanvas) -> Point {
        Point(
            x: min(max(0, canvas.width - 1), max(0, point.x)),
            y: min(max(0, canvas.height - 1), max(0, point.y))
        )
    }
}
