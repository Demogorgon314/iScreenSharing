import Combine
import CoreGraphics

struct AppleDisplayInputMapping: Equatable {
    let backingFrame: CGRect
    let logicalFrame: CGRect
    let localSourceSize: CGSize?

    init(
        backingFrame: CGRect,
        logicalFrame: CGRect,
        localSourceSize: CGSize? = nil
    ) {
        self.backingFrame = backingFrame
        self.logicalFrame = logicalFrame
        self.localSourceSize = localSourceSize
    }

    func point(from backingPoint: CGPoint, isDisplayLocal: Bool) -> (x: Int, y: Int)? {
        guard backingFrame.width > 0, backingFrame.height > 0,
              logicalFrame.width > 0, logicalFrame.height > 0 else { return nil }
        if isDisplayLocal {
            let sourceSize = localSourceSize ?? backingFrame.size
            guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }
            let x = backingPoint.x * backingFrame.width / sourceSize.width
            let y = backingPoint.y * backingFrame.height / sourceSize.height
            return (
                Int(min(backingFrame.width - 1, max(0, x)).rounded()),
                Int(min(backingFrame.height - 1, max(0, y)).rounded())
            )
        }
        let localX = backingPoint.x - backingFrame.minX
        let localY = backingPoint.y - backingFrame.minY
        let x = logicalFrame.minX + localX * logicalFrame.width / backingFrame.width
        let y = logicalFrame.minY + localY * logicalFrame.height / backingFrame.height
        return (
            Int(min(logicalFrame.maxX - 1, max(logicalFrame.minX, x)).rounded()),
            Int(min(logicalFrame.maxY - 1, max(logicalFrame.minY, y)).rounded())
        )
    }
}

@MainActor
final class AppleDisplayLayoutModel: ObservableObject {
    @Published private(set) var layout: AppleDisplayLayout?
    private let expectedDisplayCount: Int
    private var mediaDisplayIDs = [UInt32]()

    init(expectedDisplayCount: Int = 1) {
        self.expectedDisplayCount = max(1, expectedDisplayCount)
    }

    var displayCount: Int { layout?.displays.count ?? expectedDisplayCount }
    var supportsDynamicResolution: Bool {
        expectedDisplayCount == 1 && displayCount == 1
    }

    func receive(_ layout: AppleDisplayLayout) {
        guard layout.displays.count >= expectedDisplayCount else { return }
        guard let currentLayout = self.layout else {
            mediaDisplayIDs = layout.displays.map(\.displayID)
            self.layout = layout
            return
        }
        guard layout != currentLayout else { return }

        let displays = layout.displays.count > 1
            ? layout.displays.sorted(by: Self.isSpatiallyOrdered)
            : layout.displays
        self.layout = AppleDisplayLayout(
            scaledWidth: layout.scaledWidth,
            scaledHeight: layout.scaledHeight,
            backingWidth: layout.backingWidth,
            backingHeight: layout.backingHeight,
            displays: displays
        )
    }

    private static func isSpatiallyOrdered(_ lhs: AppleDisplayRect, _ rhs: AppleDisplayRect) -> Bool {
        if lhs.logicalX != rhs.logicalX { return lhs.logicalX < rhs.logicalX }
        if lhs.logicalY != rhs.logicalY { return lhs.logicalY < rhs.logicalY }
        if lhs.logicalWidth != rhs.logicalWidth { return lhs.logicalWidth < rhs.logicalWidth }
        if lhs.logicalHeight != rhs.logicalHeight { return lhs.logicalHeight < rhs.logicalHeight }
        return lhs.displayID < rhs.displayID
    }

    func sourceRect(for displayIndex: Int) -> CGRect? {
        guard let displays = layout?.displays,
              displays.count > 1,
              displays.indices.contains(displayIndex) else { return nil }
        let display = displays[displayIndex]
        return CGRect(
            x: display.x,
            y: display.y,
            width: display.width,
            height: display.height
        )
    }

    func displayID(for displayIndex: Int) -> UInt32? {
        inputDisplay(for: displayIndex)?.displayID
    }

    func inputMapping(
        for displayIndex: Int,
        localSourceSize: CGSize? = nil
    ) -> AppleDisplayInputMapping? {
        guard displayCount > 1,
              let display = inputDisplay(for: displayIndex) else { return nil }
        return AppleDisplayInputMapping(
            backingFrame: CGRect(
                x: display.x,
                y: display.y,
                width: display.width,
                height: display.height
            ),
            logicalFrame: CGRect(
                x: display.logicalX,
                y: display.logicalY,
                width: display.logicalWidth,
                height: display.logicalHeight
            ),
            localSourceSize: localSourceSize
        )
    }

    private func inputDisplay(for displayIndex: Int) -> AppleDisplayRect? {
        guard let displays = layout?.displays,
              mediaDisplayIDs.indices.contains(displayIndex) else { return nil }
        let displayID = mediaDisplayIDs[displayIndex]
        return displays.first(where: { $0.displayID == displayID })
    }
}
