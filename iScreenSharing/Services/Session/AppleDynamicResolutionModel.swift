import Combine
import Foundation
import struct ScreenSharingProtocol.AppleCanvas
import struct ScreenSharingProtocol.AppleDisplayLayout
import struct ScreenSharingProtocol.AppleDynamicResolutionSize

@MainActor
final class AppleDynamicResolutionModel: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            cancel()
            lastRequestedSizes = nil
            didChangeEnabled(isEnabled)
            if !isEnabled { requestFixedResolutionMode() }
        }
    }
    @Published private(set) var errorMessage: String?

    private static let debounceMilliseconds = 500
    private let displayCount: Int
    private let didChangeEnabled: (Bool) -> Void
    private let requestFixedResolution: @MainActor () async throws -> Void
    private var task: Task<Void, Never>?
    private var lastRequestedSizes: [AppleDynamicResolutionSize]?
    private var pendingSizes: [AppleDynamicResolutionSize]?

    init(
        displayCount: Int = 1,
        isEnabled: Bool = true,
        didChangeEnabled: @escaping (Bool) -> Void = { _ in },
        requestFixedResolution: @escaping @MainActor () async throws -> Void = { }
    ) {
        self.displayCount = min(2, max(1, displayCount))
        self.didChangeEnabled = didChangeEnabled
        self.requestFixedResolution = requestFixedResolution
        self.isEnabled = self.displayCount == 1 && isEnabled
    }

    func schedule(
        displayIndex: Int = 0,
        viewport: CGSize,
        canvas: AppleCanvas? = nil,
        layout: AppleDisplayLayout? = nil,
        controller: AppleDynamicResolutionController,
        waitsForViewportToSettle: Bool = true
    ) {
        guard displayCount == 1,
              isEnabled,
              (0..<displayCount).contains(displayIndex),
              let size = AppleDynamicResolutionSize.normalized(viewport: viewport) else { return }
        let sizes = [size]
        guard sizes != lastRequestedSizes,
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
                if waitsForViewportToSettle {
                    try await Task.sleep(for: .milliseconds(Self.debounceMilliseconds))
                }
                guard let self, let controller, self.isEnabled else { return }
                try Task.checkCancellation()
                try await controller.request(displaySizes: sizes)
                self.lastRequestedSizes = sizes
                if self.pendingSizes == sizes { self.pendingSizes = nil }
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

    private func requestFixedResolutionMode() {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try await requestFixedResolution()
                try Task.checkCancellation()
                errorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
