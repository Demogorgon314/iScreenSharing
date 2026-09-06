import CoreGraphics
import Foundation

/// Local presentation only; zoom never changes the negotiated remote canvas.
struct MobileCanvasViewport {
    private(set) var scale: CGFloat = 1
    private var offset = CGPoint.zero
    var topContentInset: CGFloat = 0

    init(topContentInset: CGFloat = 0) {
        self.topContentInset = topContentInset
    }

    mutating func reset() { self = Self(topContentInset: topContentInset) }

    /// Fit avoids the overlaid navigation controls; zoom can use the area
    /// behind them without changing the base scale or pointer mapping.
    func fittingBounds(in bounds: CGRect) -> CGRect {
        let inset = topContentInset.isFinite ? min(max(0, topContentInset), max(0, bounds.height - 1)) : 0
        return CGRect(x: bounds.minX, y: bounds.minY + inset, width: bounds.width, height: bounds.height - inset)
    }

    func frame(base: CGRect, bounds: CGRect) -> CGRect {
        guard !base.isEmpty, !bounds.isEmpty else { return .zero }
        let size = CGSize(width: base.width * scale, height: base.height * scale)
        let x = size.width <= bounds.width
            ? bounds.midX - size.width / 2
            : min(bounds.minX, max(bounds.maxX - size.width, base.minX + offset.x))
        let y: CGFloat
        if topContentInset > 0 {
            if scale == 1 {
                y = base.minY
            } else {
                // Permit panning beneath the toolbar, but also allow the top
                // desktop edge to be brought back below it for interaction.
                let fitBounds = fittingBounds(in: bounds)
                let upper = fitBounds.height > fitBounds.width ? fitBounds.minY
                    : max(fitBounds.minY, fitBounds.midY - size.height / 2)
                y = min(upper,
                        max(min(bounds.minY, bounds.maxY - size.height), base.minY + offset.y))
            }
        } else if size.height <= bounds.height {
            y = bounds.height > bounds.width ? bounds.minY : bounds.midY - size.height / 2
        } else {
            y = min(bounds.minY, max(bounds.maxY - size.height, base.minY + offset.y))
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    mutating func zoom(
        by factor: CGFloat, around anchor: CGPoint, translation: CGPoint,
        base: CGRect, bounds: CGRect
    ) {
        guard factor.isFinite, factor > 0, anchor.x.isFinite, anchor.y.isFinite,
              translation.x.isFinite, translation.y.isFinite,
              !base.isEmpty, !bounds.isEmpty else { return }
        let previous = frame(base: base, bounds: bounds)
        let nextScale = min(4, max(1, scale * factor))
        let ratio = nextScale / scale
        offset = CGPoint(
            x: anchor.x + (previous.minX - anchor.x) * ratio + translation.x - base.minX,
            y: anchor.y + (previous.minY - anchor.y) * ratio + translation.y - base.minY
        )
        scale = nextScale
        constrain(base: base, bounds: bounds)
    }

    mutating func pan(by translation: CGPoint, base: CGRect, bounds: CGRect) {
        zoom(by: 1, around: .zero, translation: translation, base: base, bounds: bounds)
    }

    mutating func constrain(base: CGRect, bounds: CGRect) {
        let visible = frame(base: base, bounds: bounds)
        guard !visible.isEmpty else { return }
        offset = CGPoint(x: visible.minX - base.minX, y: visible.minY - base.minY)
    }

    /// Follow relative pointer movement without moving the remote pointer or
    /// exposing empty space beyond the desktop. Manual viewport gestures do
    /// not call this, so they can freely explore away from the cursor.
    @discardableResult
    mutating func reveal(basePoint: CGPoint, base: CGRect, bounds: CGRect) -> Bool {
        guard scale > 1, !base.isEmpty, !bounds.isEmpty,
              basePoint.x.isFinite, basePoint.y.isFinite else { return false }
        let previous = frame(base: base, bounds: bounds)
        let point = CGPoint(
            x: previous.minX + (basePoint.x - base.minX) * scale,
            y: previous.minY + (basePoint.y - base.minY) * scale
        )
        let unobscured = fittingBounds(in: bounds)
        let safe = unobscured.insetBy(dx: min(24, unobscured.width / 4), dy: min(24, unobscured.height / 4))
        func correction(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
            if value < minimum { return minimum - value }
            if value > maximum { return maximum - value }
            return 0
        }
        let translation = CGPoint(
            x: previous.width > bounds.width ? correction(point.x, minimum: safe.minX, maximum: safe.maxX) : 0,
            y: previous.height > bounds.height || topContentInset > 0
                ? correction(point.y, minimum: safe.minY, maximum: safe.maxY) : 0
        )
        pan(by: translation, base: base, bounds: bounds)
        return frame(base: base, bounds: bounds) != previous
    }

    func unscaledTranslation(_ translation: CGPoint) -> CGPoint {
        CGPoint(x: translation.x / scale, y: translation.y / scale)
    }

    func unproject(_ point: CGPoint, base: CGRect, bounds: CGRect) -> CGPoint {
        let visible = frame(base: base, bounds: bounds)
        return CGPoint(
            x: base.minX + (point.x - visible.minX) / scale,
            y: base.minY + (point.y - visible.minY) / scale
        )
    }
}

/// Classifies one two-finger contact sequence once, so a pinch cannot also
/// send wheel events. Initial movement is retained until the intent is known.
struct MobileTwoFingerGestureState {
    enum Mode { case scrolling, zooming }
    struct Update {
        let mode: Mode
        let translation: CGPoint
        let scale: CGFloat
        let anchor: CGPoint
    }

    private(set) var mode: Mode?
    private var initialCenter = CGPoint.zero
    private var initialDistance: CGFloat = 0
    private var initialFirst = CGPoint.zero
    private var initialSecond = CGPoint.zero
    private var movementStartedAt: TimeInterval?
    private var previousCenter = CGPoint.zero
    private var previousDistance: CGFloat = 0

    mutating func begin(first: CGPoint, second: CGPoint) {
        self = Self()
        initialFirst = first
        initialSecond = second
        initialCenter = CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
        initialDistance = hypot(first.x - second.x, first.y - second.y)
        previousCenter = initialCenter
        previousDistance = initialDistance
    }

    mutating func update(first: CGPoint, second: CGPoint, timestamp: TimeInterval = 0) -> Update? {
        guard first.x.isFinite, first.y.isFinite, second.x.isFinite, second.y.isFinite,
              initialDistance > 0, initialDistance.isFinite, timestamp.isFinite else { return nil }
        let center = CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
        let distance = hypot(first.x - second.x, first.y - second.y)
        guard distance > 0 else { return nil }
        if mode == nil {
            let travel = hypot(center.x - initialCenter.x, center.y - initialCenter.y)
            let separation = abs(distance - initialDistance)
            guard travel >= 4 || separation >= 6 else {
                movementStartedAt = nil
                return nil
            }
            let firstMotion = CGPoint(x: first.x - initialFirst.x, y: first.y - initialFirst.y)
            let secondMotion = CGPoint(x: second.x - initialSecond.x, y: second.y - initialSecond.y)
            let firstLength = hypot(firstMotion.x, firstMotion.y)
            let secondLength = hypot(secondMotion.x, secondMotion.y)
            let dot = firstMotion.x * secondMotion.x + firstMotion.y * secondMotion.y
            let parallel = min(firstLength, secondLength) >= 1.5
                && min(firstLength, secondLength) >= max(firstLength, secondLength) * 0.35
                && dot >= firstLength * secondLength * 0.8
            if parallel, travel >= 4 {
                mode = .scrolling
            } else if separation >= 6, dot < 0 {
                mode = .zooming
            } else if travel >= 4, separation < travel * 0.5 {
                mode = .scrolling
            } else {
                // A leading scroll finger and an anchored pinch are initially
                // indistinguishable. Give the other finger 40 ms to join before
                // locking intent; clear parallel/opposing movement never waits.
                if movementStartedAt == nil { movementStartedAt = timestamp }
                guard timestamp - (movementStartedAt ?? timestamp) >= 0.04 else { return nil }
                mode = separation >= 6 && separation >= travel ? .zooming : .scrolling
            }
        }
        guard let mode else { return nil }
        let result = Update(
            mode: mode,
            translation: CGPoint(x: center.x - previousCenter.x, y: center.y - previousCenter.y),
            scale: distance / previousDistance,
            anchor: previousCenter
        )
        previousCenter = center
        previousDistance = distance
        return result
    }
}
