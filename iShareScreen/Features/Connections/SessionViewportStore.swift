import CoreGraphics
import Foundation

struct SessionViewportStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func size(for endpoint: ConnectionEndpoint) -> CGSize? {
        guard let values = defaults.array(forKey: key(for: endpoint)) as? [NSNumber],
              values.count == 2 else { return nil }
        let size = CGSize(width: values[0].doubleValue, height: values[1].doubleValue)
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return size
    }

    func save(_ size: CGSize, for endpoint: ConnectionEndpoint) {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return }
        defaults.set([size.width, size.height], forKey: key(for: endpoint))
    }

    private func key(for endpoint: ConnectionEndpoint) -> String {
        "SessionViewport.\(endpoint.url.absoluteString)"
    }
}
