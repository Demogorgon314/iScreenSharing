import CoreGraphics
import Foundation

struct SessionViewportStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func size(for endpoint: ConnectionEndpoint, displayIndex: Int = 0) -> CGSize? {
        guard displayIndex >= 0,
              let values = defaults.array(forKey: key(for: endpoint, displayIndex: displayIndex)) as? [NSNumber],
              values.count == 2 else { return nil }
        let size = CGSize(width: values[0].doubleValue, height: values[1].doubleValue)
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return size
    }

    func save(_ size: CGSize, for endpoint: ConnectionEndpoint, displayIndex: Int = 0) {
        guard displayIndex >= 0,
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return }
        defaults.set(
            [size.width, size.height],
            forKey: key(for: endpoint, displayIndex: displayIndex)
        )
    }

    private func key(for endpoint: ConnectionEndpoint, displayIndex: Int) -> String {
        let base = "SessionViewport.\(endpoint.url.absoluteString)"
        return displayIndex == 0 ? base : "\(base).Display\(displayIndex + 1)"
    }
}
