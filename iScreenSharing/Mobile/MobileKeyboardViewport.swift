import CoreGraphics

enum MobileKeyboardViewport {
    /// The largest rectangular area not covered by a docked or floating
    /// keyboard. A floating keyboard must not be treated as a full-width inset.
    static func availableBounds(in bounds: CGRect, avoiding keyboard: CGRect) -> CGRect {
        let overlap = bounds.intersection(keyboard)
        guard !overlap.isNull, !overlap.isEmpty else { return bounds }
        let candidates = [
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: overlap.minY - bounds.minY),
            CGRect(x: bounds.minX, y: overlap.maxY, width: bounds.width, height: bounds.maxY - overlap.maxY),
            CGRect(x: bounds.minX, y: bounds.minY, width: overlap.minX - bounds.minX, height: bounds.height),
            CGRect(x: overlap.maxX, y: bounds.minY, width: bounds.maxX - overlap.maxX, height: bounds.height),
        ].filter { !$0.isEmpty }
        return candidates.max { $0.width * $0.height < $1.width * $1.height } ?? bounds
    }
}
