import CoreGraphics
import ScreenSharingProtocol

extension ScreenSharingProtocol.AppleDynamicResolutionSize {
    static func normalized(viewport: CGSize) -> Self? {
        guard viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0 else { return nil }
        let width = Int(min(1_920, max(800, viewport.width)).rounded(.down))
        let height = Int(min(1_080, max(600, viewport.height)).rounded(.down))
        return Self(width: width, height: height)
    }
}

extension ScreenSharingProtocol.AppleDisplayLayout {
    func canvas(tileCount: Int) -> AppleCanvas {
        AppleCanvas(width: backingWidth, height: backingHeight, tileCount: tileCount)
    }
}
