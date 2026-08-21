import Combine
import CoreGraphics

@MainActor
final class AppleDisplayLayoutModel: ObservableObject {
    @Published private(set) var layout: AppleDisplayLayout?
    private let expectedDisplayCount: Int

    init(expectedDisplayCount: Int = 1) {
        self.expectedDisplayCount = max(1, expectedDisplayCount)
    }

    var displayCount: Int { layout?.displays.count ?? expectedDisplayCount }
    var supportsDynamicResolution: Bool {
        expectedDisplayCount == 1 && displayCount == 1
    }

    func receive(_ layout: AppleDisplayLayout) {
        self.layout = layout
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

    func inputOrigin(for displayIndex: Int) -> CGPoint {
        guard let displays = layout?.displays,
              displays.indices.contains(displayIndex) else { return .zero }
        return CGPoint(x: displays[displayIndex].x, y: displays[displayIndex].y)
    }
}
