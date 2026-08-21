import Combine
import Foundation

@MainActor
final class AppleDynamicResolutionModel: ObservableObject {
    @Published var isEnabled = true {
        didSet {
            if !isEnabled { cancel() }
        }
    }
    @Published private(set) var errorMessage: String?

    private static let debounceMilliseconds = 500
    private static let minimumRequestInterval: TimeInterval = 2.5

    private let displayCount: Int
    private var task: Task<Void, Never>?
    private var viewportSizes = [Int: AppleDynamicResolutionSize]()
    private var lastRequestedSizes: [AppleDynamicResolutionSize]?
    private var pendingSizes: [AppleDynamicResolutionSize]?
    private var lastRequestTime: TimeInterval?

    init(displayCount: Int = 1) {
        self.displayCount = min(2, max(1, displayCount))
    }

    func schedule(
        displayIndex: Int = 0,
        viewport: CGSize,
        canvas: AppleCanvas? = nil,
        layout: AppleDisplayLayout? = nil,
        controller: AppleDynamicResolutionController
    ) {
        guard isEnabled,
              (0..<displayCount).contains(displayIndex),
              let size = AppleDynamicResolutionSize.normalized(viewport: viewport) else { return }
        viewportSizes[displayIndex] = size
        let sizes = (0..<displayCount).compactMap { viewportSizes[$0] }
        guard sizes.count == displayCount,
              sizes != lastRequestedSizes,
              sizes != pendingSizes else { return }
        if displayCount == 1, let canvas,
           canvas.width == size.width * 2,
           canvas.height == size.height * 2 {
            lastRequestedSizes = sizes
            return
        }
        if let displays = layout?.displays,
           displays.count == displayCount,
           zip(displays, sizes).allSatisfy({ pair in
               pair.0.width == pair.1.width * 2 && pair.0.height == pair.1.height * 2
           }) {
            lastRequestedSizes = sizes
            return
        }
        task?.cancel()
        pendingSizes = sizes
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
                try await controller.request(displaySizes: sizes)
                self.lastRequestedSizes = sizes
                if self.pendingSizes == sizes { self.pendingSizes = nil }
                self.lastRequestTime = ProcessInfo.processInfo.systemUptime
                self.errorMessage = nil
            } catch is CancellationError {
                if self?.pendingSizes == sizes { self?.pendingSizes = nil }
                return
            } catch {
                if self?.pendingSizes == sizes { self?.pendingSizes = nil }
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        pendingSizes = nil
    }

    func clearError() {
        errorMessage = nil
    }
}
