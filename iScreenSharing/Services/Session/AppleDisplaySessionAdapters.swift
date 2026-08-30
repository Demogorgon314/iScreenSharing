import CoreGraphics
import ScreenSharingProtocol

extension ScreenSharingProtocol.AppleDynamicResolutionSize {
    static func normalized(viewport: CGSize) -> Self? {
        guard viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0 else { return nil }
        let maximumScale = min(1, 1920 / viewport.width, 1080 / viewport.height)
        let boundedWidth = viewport.width * maximumScale
        let boundedHeight = viewport.height * maximumScale
        let desiredMinimumScale = max(1, 320 / boundedWidth, 200 / boundedHeight)
        let availableScale = min(1920 / boundedWidth, 1080 / boundedHeight)
        let finalScale = min(desiredMinimumScale, availableScale)
        let width = max(2, Int((boundedWidth * finalScale).rounded(.down)) & ~1)
        let height = max(2, Int((boundedHeight * finalScale).rounded(.down)) & ~1)
        return Self(width: width, height: height)
    }
}

extension ScreenSharingProtocol.AppleDisplayLayout {
    func canvas(tileCount: Int) -> AppleCanvas {
        AppleCanvas(width: backingWidth, height: backingHeight, tileCount: tileCount)
    }
}
