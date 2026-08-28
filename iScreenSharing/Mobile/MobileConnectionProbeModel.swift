import Foundation

@MainActor
final class MobileConnectionProbeModel: ObservableObject {
    enum State: Equatable {
        case idle
        case probing
        case ready
        case unsupported
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let endpoint: ConnectionEndpoint
    private let probe: any RFBProbing

    init(endpoint: ConnectionEndpoint, probe: any RFBProbing = RFBProbeService()) {
        self.endpoint = endpoint
        self.probe = probe
    }

    func start() async {
        guard state != .probing else { return }
        state = .probing
        do {
            let result = try await probe.probe(endpoint)
            guard !Task.isCancelled else { return }
            state = result.securityTypes.contains(.appleRSA) ? .ready : .unsupported
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
