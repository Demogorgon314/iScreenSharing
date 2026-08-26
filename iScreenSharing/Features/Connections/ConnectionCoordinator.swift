import Combine
import Foundation

@MainActor
final class ConnectionCoordinator: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case ready(RFBProbeResult)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let probeService: any RFBProbing
    private var task: Task<Void, Never>?

    init(probeService: any RFBProbing = RFBProbeService()) {
        self.probeService = probeService
    }

    func connect(to endpoint: ConnectionEndpoint) {
        task?.cancel()
        state = .connecting
        task = Task {
            do {
                let result = try await probeService.probe(endpoint)
                try Task.checkCancellation()
                state = .ready(result)
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }
}
