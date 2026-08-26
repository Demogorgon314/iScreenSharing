import Combine
import Foundation

@MainActor
final class TailscaleModel: ObservableObject {
    @Published private(set) var state: EmbeddedTailscaleState = .starting
    @Published private(set) var peers = [TailscalePeer]()
    @Published private(set) var authenticationURL: URL?
    @Published private(set) var isLinkingAccount = false
    @Published private(set) var isLoggingOut = false
    @Published private(set) var logoutErrorMessage: String?

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
        guard !isLinkingAccount else { return }
        logoutErrorMessage = nil
        isLinkingAccount = true
        let runtime = runtime
        Task { [weak self] in
            do {
                try await runtime.startLogin()
            } catch {
                self?.isLinkingAccount = false
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    func retry() {
        observationTask?.cancel()
        observationTask = nil
        start()
    }

    func logout() async {
        guard !isLoggingOut else { return }
        isLoggingOut = true
        logoutErrorMessage = nil
        defer { isLoggingOut = false }

        do {
            try await runtime.logout()
            authenticationURL = nil
            peers = []
            state = .needsLogin
        } catch {
            logoutErrorMessage = "Couldn’t log out of Tailscale. Try again."
        }
    }

    private func apply(_ event: EmbeddedTailscaleEvent) {
        switch event {
        case .state(let state):
            self.state = state
            if state == .running || state == .needsMachineApproval {
                isLinkingAccount = false
            }
            if state == .needsLogin {
                peers = []
                authenticationURL = nil
            }
        case .peers(let peers):
            self.peers = peers
        case .authenticationURL(let url):
            authenticationURL = url
            isLinkingAccount = false
        }
    }
}
