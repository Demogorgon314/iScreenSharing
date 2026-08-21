import Combine
import CoreGraphics
import Foundation

struct AppleDynamicResolutionSize: Equatable, Sendable {
    let width: Int
    let height: Int

    static func normalized(viewport: CGSize) -> AppleDynamicResolutionSize? {
        guard viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0 else { return nil }
        let width = min(1920, max(640, Int(viewport.width.rounded(.down)))) & ~1
        let height = min(1080, max(480, Int(viewport.height.rounded(.down)))) & ~1
        return AppleDynamicResolutionSize(width: width, height: height)
    }
}

@MainActor
final class AppleDynamicResolutionModel: ObservableObject {
    @Published var isEnabled = true {
        didSet {
            if !isEnabled { task?.cancel() }
        }
    }
    @Published private(set) var errorMessage: String?

    private static let debounceMilliseconds = 500
    private static let minimumRequestInterval: TimeInterval = 2.5

    private var task: Task<Void, Never>?
    private var lastRequestedSize: AppleDynamicResolutionSize?
    private var lastRequestTime: TimeInterval?

    func schedule(viewport: CGSize, controller: AppleDynamicResolutionController) {
        guard isEnabled, let size = AppleDynamicResolutionSize.normalized(viewport: viewport),
              size != lastRequestedSize else { return }
        task?.cancel()
        task = Task { [weak self, weak controller] in
            do {
                try await Task.sleep(for: .milliseconds(Self.debounceMilliseconds))
                guard let self, let controller, self.isEnabled else { return }
                if let lastRequestTime = self.lastRequestTime {
                    let elapsed = ProcessInfo.processInfo.systemUptime - lastRequestTime
                    let remaining = Self.minimumRequestInterval - elapsed
                    if remaining > 0 {
                        try await Task.sleep(for: .milliseconds(Int(remaining * 1_000)))
                    }
                }
                try Task.checkCancellation()
                try await controller.request(width: size.width, height: size.height)
                self.lastRequestedSize = size
                self.lastRequestTime = ProcessInfo.processInfo.systemUptime
                self.errorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func clearError() {
        errorMessage = nil
    }
}
