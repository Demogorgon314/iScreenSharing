import CoreGraphics
import struct ScreenSharingProtocol.AppleCanvas

struct MobileRemotePointerState {
    private static let relativeMovementScale: CGFloat = 4

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
        guard !bounds.isEmpty else { return current }

        fractionalX += localTranslation.x * Self.relativeMovementScale
        fractionalY += localTranslation.y * Self.relativeMovementScale
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
#if os(macOS)
        guard let mapped = AppleVideoCanvasLayout.remotePoint(
            location: localPoint,
            canvas: canvas,
            bounds: bounds,
            fixedScale: nil
        ) else { return nil }
#else
        guard let mapped = AppleVideoCanvasLayout.remotePoint(
            location: localPoint,
            canvas: canvas,
            bounds: bounds
        ) else { return nil }
#endif
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

enum MobileRemotePointerPath {
    static func interpolatedPoints(
        from start: MobileRemotePointerState.Point,
        to end: MobileRemotePointerState.Point,
        maximumStep: Double = 8
    ) -> [MobileRemotePointerState.Point] {
        precondition(maximumStep > 0)
        let distance = hypot(Double(end.x - start.x), Double(end.y - start.y))
        guard distance > 0 else { return [] }
        let stepCount = max(1, Int(ceil(distance / maximumStep)))
        var points = [MobileRemotePointerState.Point]()
        points.reserveCapacity(stepCount)
        for step in 1...stepCount {
            let progress = Double(step) / Double(stepCount)
            let point = MobileRemotePointerState.Point(
                x: start.x + Int((Double(end.x - start.x) * progress).rounded()),
                y: start.y + Int((Double(end.y - start.y) * progress).rounded())
            )
            if points.last != point { points.append(point) }
        }
        return points
    }
}
