import Combine
import Foundation

@MainActor
final class TailscaleModel: ObservableObject {
    @Published private(set) var state: EmbeddedTailscaleState = .starting
    @Published private(set) var peers = [TailscalePeer]()
    @Published private(set) var authenticationURL: URL?

    private let runtime: any EmbeddedTailscaleRunning
    private var observationTask: Task<Void, Never>?

    init(runtime: any EmbeddedTailscaleRunning = EmbeddedTailscaleRuntime.shared) {
        self.runtime = runtime
    }

    deinit {
        observationTask?.cancel()
    }

    func start() {
        guard observationTask == nil else { return }
        let runtime = runtime
        observationTask = Task { [weak self] in
            let events = await runtime.events()
            do {
                try await runtime.start()
                for await event in events {
                    guard !Task.isCancelled, let self else { return }
                    apply(event)
                }
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    func linkAccount() {
        state = .starting
        let runtime = runtime
        Task { [weak self] in
            do {
                try await runtime.startLogin()
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    func retry() {
        observationTask?.cancel()
        observationTask = nil
        start()
    }

    private func apply(_ event: EmbeddedTailscaleEvent) {
        switch event {
        case .state(let state):
            self.state = state
        case .peers(let peers):
            self.peers = peers
        case .authenticationURL(let url):
            authenticationURL = url
        }
    }
}
