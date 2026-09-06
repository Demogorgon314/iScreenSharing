import Foundation

protocol SessionRouteOpening: Sendable {
    func open(
        _ endpoint: ConnectionEndpoint,
        sharingType: ScreenSharingType
    ) async throws -> any OpenSessionRoute
}

protocol OpenSessionRoute: AnyObject, Sendable {
    var control: any RFBTransport { get }
    var remoteAddress: ResolvedRemoteAddress { get }

    func openHighPerformanceMedia(
        displayCount: Int
    ) async throws -> any AppleMediaReceiving
    func close()
}

enum SessionRouteError: LocalizedError, Equatable {
    case mediaUnavailableForStandardMode
    case mediaAlreadyOpened
    case closed

    var errorDescription: String? {
        switch self {
        case .mediaUnavailableForStandardMode:
            "Standard Screen Sharing does not use a high-performance media route."
        case .mediaAlreadyOpened:
            "The high-performance media route has already been opened."
        case .closed:
            "The Screen Sharing route is closed."
        }
    }
}

struct SessionRouteOpener: SessionRouteOpening {
    private let direct: any SessionRouteAdapter
    private let tailscale: any SessionRouteAdapter

    init(
        direct: any SessionRouteAdapter = DirectSessionRouteAdapter(),
        tailscale: any SessionRouteAdapter = TailscaleSessionRouteAdapter()
    ) {
        self.direct = direct
        self.tailscale = tailscale
    }

    func open(
        _ endpoint: ConnectionEndpoint,
        sharingType: ScreenSharingType
    ) async throws -> any OpenSessionRoute {
        switch endpoint.route {
        case .direct:
            try await direct.open(endpoint, sharingType: sharingType)
        case .tailscale:
            try await tailscale.open(endpoint, sharingType: sharingType)
        }
    }
}

protocol SessionRouteAdapter: Sendable {
    func open(
        _ endpoint: ConnectionEndpoint,
        sharingType: ScreenSharingType
    ) async throws -> any OpenSessionRoute
}

struct DirectSessionRouteAdapter: SessionRouteAdapter {
    typealias MakeTransport = @Sendable (ResolvedRemoteAddress) -> any RFBTransport
    typealias MakeMedia = @Sendable (
        ResolvedRemoteAddress,
        Int
    ) async throws -> any AppleMediaReceiving

    private let addressResolver: any RemoteAddressResolving
    private let makeTransport: MakeTransport
    private let makeMedia: MakeMedia

    init(
        addressResolver: any RemoteAddressResolving = RemoteAddressResolver(),
        makeTransport: @escaping MakeTransport = { NWConnectionTransport(remoteAddress: $0) },
        makeMedia: @escaping MakeMedia = { address, displayCount in
            try AppleMediaReceiver(remoteAddress: address, displayCount: displayCount)
        }
    ) {
        self.addressResolver = addressResolver
        self.makeTransport = makeTransport
        self.makeMedia = makeMedia
    }

    func open(
        _ endpoint: ConnectionEndpoint,
        sharingType: ScreenSharingType
    ) async throws -> any OpenSessionRoute {
        let timing = ConnectionStartupTrace.current
        timing?.record(.resolutionStarted)
        let addresses = try await addressResolver.resolve(endpoint)
        timing?.record(.resolutionReady, since: .init(.resolutionStarted), count: addresses.count)
        var lastError: Error?
        for (index, address) in addresses.enumerated() {
            timing?.record(.tcpStarted, index: index)
            let transport = makeTransport(address)
            do {
                try await transport.start()
                timing?.record(.tcpReady, index: index, since: .init(.tcpStarted, index: index))
                return ManagedSessionRoute(
                    control: transport,
                    remoteAddress: address,
                    sharingType: sharingType,
                    makeMedia: makeMedia
                )
            } catch is CancellationError {
                transport.cancel()
                throw CancellationError()
            } catch {
                timing?.record(.tcpFailed, index: index, since: .init(.tcpStarted, index: index))
                transport.cancel()
                lastError = error
            }
        }
        throw lastError ?? RemoteAddressResolverError.noUsableAddress
    }
}

struct TailscaleSessionRouteAdapter: SessionRouteAdapter {
    private let nodeProvider: any TailscaleNodeProviding

    init(nodeProvider: any TailscaleNodeProviding = EmbeddedTailscaleRuntime.shared) {
        self.nodeProvider = nodeProvider
    }

    func open(
        _ endpoint: ConnectionEndpoint,
        sharingType: ScreenSharingType
    ) async throws -> any OpenSessionRoute {
        let remoteAddress = try ResolvedRemoteAddress(
            numericHost: endpoint.host,
            port: endpoint.port
        )
        let transport = TailscaleTCPTransport(
            endpoint: endpoint,
            nodeProvider: nodeProvider
        )
        do {
            try await transport.start()
            return ManagedSessionRoute(
                control: transport,
                remoteAddress: remoteAddress,
                sharingType: sharingType
            ) { [nodeProvider] address, displayCount in
                try await TailscaleMediaReceiver.create(
                    remoteAddress: address,
                    displayCount: displayCount,
                    nodeProvider: nodeProvider
                )
            }
        } catch {
            transport.cancel()
            throw error
        }
    }
}

final class ManagedSessionRoute: OpenSessionRoute, @unchecked Sendable {
    typealias MakeMedia = @Sendable (
        ResolvedRemoteAddress,
        Int
    ) async throws -> any AppleMediaReceiving

    let control: any RFBTransport
    let remoteAddress: ResolvedRemoteAddress

    private enum MediaState {
        case available
        case opening
        case opened(any AppleMediaReceiving)
        case closed
    }

    private let sharingType: ScreenSharingType
    private let makeMedia: MakeMedia
    private let lock = NSLock()
    private var mediaState: MediaState = .available

    init(
        control: any RFBTransport,
        remoteAddress: ResolvedRemoteAddress,
        sharingType: ScreenSharingType,
        makeMedia: @escaping MakeMedia
    ) {
        self.control = control
        self.remoteAddress = remoteAddress
        self.sharingType = sharingType
        self.makeMedia = makeMedia
    }

    func openHighPerformanceMedia(
        displayCount: Int
    ) async throws -> any AppleMediaReceiving {
        guard sharingType == .highPerformance else {
            throw SessionRouteError.mediaUnavailableForStandardMode
        }
        try lock.withLock {
            switch mediaState {
            case .available:
                mediaState = .opening
            case .opening, .opened:
                throw SessionRouteError.mediaAlreadyOpened
            case .closed:
                throw SessionRouteError.closed
            }
        }

        do {
            let receiver = try await makeMedia(remoteAddress, displayCount)
            let accepted = lock.withLock { () -> Bool in
                guard case .opening = mediaState else { return false }
                mediaState = .opened(receiver)
                return true
            }
            guard accepted else {
                receiver.close()
                throw SessionRouteError.closed
            }
            return receiver
        } catch {
            lock.withLock {
                if case .opening = mediaState {
                    mediaState = .available
                }
            }
            throw error
        }
    }

    func close() {
        let resources = lock.withLock { () -> ((any AppleMediaReceiving)?, Bool) in
            switch mediaState {
            case let .opened(receiver):
                mediaState = .closed
                return (receiver, true)
            case .available, .opening:
                mediaState = .closed
                return (nil, true)
            case .closed:
                return (nil, false)
            }
        }
        resources.0?.close()
        if resources.1 {
            control.cancel()
        }
    }
}
