import CoreGraphics

struct AppleVideoDisplayScale: Equatable {
    static let minimum: CGFloat = 0.25
    static let maximum: CGFloat = 4
    static let step: CGFloat = 1.25

    var fixedScale: CGFloat?

    init(fixedScale: CGFloat? = nil) {
        self.fixedScale = fixedScale.map { min(Self.maximum, max(Self.minimum, $0)) }
    }

    var scalesToFit: Bool { fixedScale == nil }

    mutating func toggleScaling() {
        fixedScale = scalesToFit ? 1 : nil
    }

    mutating func setScalesToFit(_ scalesToFit: Bool) {
        guard self.scalesToFit != scalesToFit else { return }
        toggleScaling()
    }

    mutating func actualSize() {
        fixedScale = 1
    }

    mutating func zoomIn() {
        fixedScale = min(Self.maximum, (fixedScale ?? 1) * Self.step)
    }

    mutating func zoomOut() {
        fixedScale = max(Self.minimum, (fixedScale ?? 1) / Self.step)
    }
}
