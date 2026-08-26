import Foundation
import TailscaleKit

enum EmbeddedTailscaleState: Equatable, Sendable {
    case starting
    case needsLogin
    case needsMachineApproval
    case running
    case stopped
    case failed(String)
}

struct TailscalePeer: Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let dnsName: String
    let addresses: [String]
    let isOnline: Bool

    var preferredAddress: String? {
        addresses.first(where: { !$0.contains(":") }) ?? addresses.first
    }

    var endpoint: ConnectionEndpoint? {
        guard let preferredAddress else { return nil }
        return try? ConnectionEndpoint(host: preferredAddress, route: .tailscale)
    }
}

enum EmbeddedTailscaleEvent: Equatable, Sendable {
    case state(EmbeddedTailscaleState)
    case peers([TailscalePeer])
    case authenticationURL(URL)
}

protocol EmbeddedTailscaleRunning: Actor {
    func events() -> AsyncStream<EmbeddedTailscaleEvent>
    func start() async throws
    func startLogin() async throws
}

protocol TailscaleNodeProviding: Actor {
    func start() async throws
    func tailscaleHandle() async throws -> TailscaleHandle
    func tailscaleLocalAddresses() async throws -> [String]
}

actor EmbeddedTailscaleRuntime: EmbeddedTailscaleRunning, TailscaleNodeProviding {
    static let shared = EmbeddedTailscaleRuntime()

    private let keyStore: any TailscaleStateKeyStoring
    private var node: TailscaleNode?
    private var localAPIClient: LocalAPIClient?
    private var busConsumer: TailscaleBusConsumer?
    private var messageProcessor: MessageProcessor?
    private var continuations = [UUID: AsyncStream<EmbeddedTailscaleEvent>.Continuation]()

    init(keyStore: any TailscaleStateKeyStoring = KeychainTailscaleStateKeyStore()) {
        self.keyStore = keyStore
    }

    func events() -> AsyncStream<EmbeddedTailscaleEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    func start() async throws {
        if let localAPIClient {
            try await publishStatus(from: localAPIClient)
            return
        }

        publish(.state(.starting))
        let key = try keyStore.loadOrCreateKey()
        let stateDirectory = try Self.stateDirectory()
        let configuration = Configuration(
            hostName: Self.nodeHostName(),
            path: stateDirectory.path,
            authKey: nil,
            controlURL: kDefaultControlURL,
            stateEncryptionKey: key
        )
        let node = try await Task.detached {
            try TailscaleNode(config: configuration, logger: nil)
        }.value
        let client = LocalAPIClient(localNode: node, logger: nil)
        let consumer = TailscaleBusConsumer(runtime: self)
        let mask: Ipn.NotifyWatchOpt = [
            .initialState,
            .netmap,
            .rateLimitNetmaps,
            .noPrivateKeys,
        ]
        let processor = try await client.watchIPNBus(mask: mask, consumer: consumer)

        self.node = node
        localAPIClient = client
        busConsumer = consumer
        messageProcessor = processor
        try await publishStatus(from: client)
    }

    func startLogin() async throws {
        guard let localAPIClient else {
            throw EmbeddedTailscaleRuntimeError.notStarted
        }
        try await localAPIClient.startLoginInteractive()
        try await publishStatus(from: localAPIClient)
    }

    func tailscaleHandle() async throws -> TailscaleHandle {
        guard let node, let handle = await node.tailscale else {
            throw EmbeddedTailscaleRuntimeError.notStarted
        }
        return handle
    }

    func tailscaleLocalAddresses() async throws -> [String] {
        guard let node else { throw EmbeddedTailscaleRuntimeError.notStarted }
        let addresses = try await node.addrs()
        return [addresses.ip4, addresses.ip6].compactMap { $0 }
    }

    fileprivate func consume(_ notify: Ipn.Notify) {
        if let state = notify.State {
            publish(.state(Self.state(from: state)))
        }
        if let netMap = notify.NetMap {
            publish(.peers(Self.peers(from: netMap.Peers ?? [])))
        }
        if let value = notify.BrowseToURL, let url = URL(string: value) {
            publish(.authenticationURL(url))
        }
        if let message = notify.ErrMessage, !message.isEmpty {
            publish(.state(.failed(message)))
        }
    }

    fileprivate func consume(_ error: Error) {
        publish(.state(.failed(error.localizedDescription)))
    }

    private func publishStatus(from client: LocalAPIClient) async throws {
        let status = try await client.backendStatus()
        publish(.state(Self.state(fromBackendState: status.BackendState)))
        let peerStatuses = status.Peer.map { Array($0.values) } ?? []
        publish(.peers(Self.peers(from: peerStatuses)))
        if let url = URL(string: status.AuthURL), !status.AuthURL.isEmpty {
            publish(.authenticationURL(url))
        }
    }

    private func publish(_ event: EmbeddedTailscaleEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private static func stateDirectory() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw EmbeddedTailscaleRuntimeError.applicationSupportUnavailable
        }
        let directory = applicationSupport.appendingPathComponent("Tailscale", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func nodeHostName() -> String {
        let computerName = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let computerName, !computerName.isEmpty else { return "iScreenSharing" }
        return "iScreenSharing-(computerName)"
    }

    private static func state(from state: Ipn.State) -> EmbeddedTailscaleState {
        switch state {
        case .NoState, .Starting:
            .starting
        case .NeedsLogin:
            .needsLogin
        case .NeedsMachineAuth:
            .needsMachineApproval
        case .Stopped:
            .stopped
        case .Running:
            .running
        case .InUseOtherUser:
            .failed("The embedded Tailscale node is in use by another account.")
        @unknown default:
            .failed("The embedded Tailscale node reported an unsupported state.")
        }
    }

    private static func state(fromBackendState state: String) -> EmbeddedTailscaleState {
        switch state {
        case "NeedsLogin": .needsLogin
        case "NeedsMachineAuth": .needsMachineApproval
        case "Running": .running
        case "Stopped": .stopped
        case "NoState", "Starting": .starting
        default: .failed("Unknown Tailscale state: \(state)")
        }
    }

    private static func peers(from nodes: [Tailcfg.Node]) -> [TailscalePeer] {
        nodes.map {
            TailscalePeer(
                id: $0.StableID,
                name: $0.Hostinfo.Hostname ?? $0.ComputedName,
                dnsName: $0.Name.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
                addresses: ($0.Addresses ?? []).map(addressWithoutPrefix),
                isOnline: $0.Online ?? false
            )
        }
        .filter { !$0.addresses.isEmpty }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func peers(from nodes: [IpnState.PeerStatus]) -> [TailscalePeer] {
        nodes.map {
            TailscalePeer(
                id: $0.ID,
                name: $0.HostName.isEmpty ? $0.DNSName : $0.HostName,
                dnsName: $0.DNSName.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
                addresses: $0.TailscaleIPs ?? [],
                isOnline: $0.Online
            )
        }
        .filter { !$0.addresses.isEmpty }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func addressWithoutPrefix(_ address: String) -> String {
        String(address.split(separator: "/", maxSplits: 1).first ?? Substring(address))
    }
}

private actor TailscaleBusConsumer: MessageConsumer {
    private weak var runtime: EmbeddedTailscaleRuntime?

    init(runtime: EmbeddedTailscaleRuntime) {
        self.runtime = runtime
    }

    func notify(_ notify: Ipn.Notify) {
        let runtime = runtime
        Task { await runtime?.consume(notify) }
    }

    func error(_ error: Error) {
        let runtime = runtime
        Task { await runtime?.consume(error) }
    }
}

enum EmbeddedTailscaleRuntimeError: LocalizedError {
    case applicationSupportUnavailable
    case notStarted

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "The Application Support folder is unavailable for embedded Tailscale state."
        case .notStarted:
            "The embedded Tailscale node has not started yet."
        }
    }
}
