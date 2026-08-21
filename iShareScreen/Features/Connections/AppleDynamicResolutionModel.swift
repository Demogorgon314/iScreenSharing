import Combine
import Foundation

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

    func schedule(
        viewport: CGSize,
        canvas: AppleCanvas? = nil,
        controller: AppleDynamicResolutionController
    ) {
        guard isEnabled, let size = AppleDynamicResolutionSize.normalized(viewport: viewport),
              size != lastRequestedSize else { return }
        if let canvas,
           canvas.width == size.width * 2,
           canvas.height == size.height * 2 {
            lastRequestedSize = size
            return
        }
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
