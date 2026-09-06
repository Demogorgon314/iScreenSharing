import Combine
import Foundation
import struct ScreenSharingProtocol.AppleRemoteDeviceInfo

struct DiscoveredScreenSharingService: Equatable, Hashable, Sendable {
    let endpoint: ConnectionEndpoint
    let deviceInfo: AppleRemoteDeviceInfo?
}

@MainActor
final class NetworkDiscoveryModel: ObservableObject {
    enum State: Equatable {
        case searching
        case results([DiscoveredScreenSharingService])
        case failed(String)
    }

    @Published private(set) var state: State = .searching

    private let browser: any BonjourBrowsing
    private let deviceInfoResolver: any BonjourDeviceInfoResolving
    private var resolutionTask: Task<Void, Never>?
    private var browseGeneration = UUID()
    private var deviceInfoByEndpoint = [ConnectionEndpoint: AppleRemoteDeviceInfo]()

    init(
        browser: any BonjourBrowsing = BonjourBrowser(),
        deviceInfoResolver: any BonjourDeviceInfoResolving = BonjourDeviceInfoResolver()
    ) {
        self.browser = browser
        self.deviceInfoResolver = deviceInfoResolver
    }

    func browse() async {
        guard !Task.isCancelled else { return }
        let generation = UUID()
        browseGeneration = generation
        resolutionTask?.cancel()
        // A cancelled scene task can finish after its replacement has begun.
        // Its cleanup must not cancel the new generation's metadata lookup.
        defer {
            if Task.isCancelled, browseGeneration == generation {
                resolutionTask?.cancel()
            }
        }
        state = .searching
        for await update in browser.updates() {
            guard !Task.isCancelled, browseGeneration == generation else { return }
            switch update {
            case .searching:
                state = .searching
            case .results(let endpoints):
                publish(endpoints)
                resolveDeviceInfo(for: endpoints)
            case .failed(let message):
                resolutionTask?.cancel()
                state = .failed(message)
            }
        }
    }

    private func resolveDeviceInfo(for endpoints: [ConnectionEndpoint]) {
        resolutionTask?.cancel()
        let resolver = deviceInfoResolver
        resolutionTask = Task { [weak self] in
            await withTaskGroup(of: (ConnectionEndpoint, AppleRemoteDeviceInfo?).self) { group in
                for endpoint in endpoints {
                    group.addTask {
                        (endpoint, await resolver.deviceInfo(for: endpoint))
                    }
                }
                for await (endpoint, info) in group {
                    guard !Task.isCancelled, let self else { return }
                    if let info {
                        self.deviceInfoByEndpoint[endpoint] = info
                        self.publish(endpoints)
                    }
                }
            }
        }
    }

    private func publish(_ endpoints: [ConnectionEndpoint]) {
        let current = Set(endpoints)
        deviceInfoByEndpoint = deviceInfoByEndpoint.filter { current.contains($0.key) }
        state = .results(endpoints.map {
            DiscoveredScreenSharingService(
                endpoint: $0,
                deviceInfo: deviceInfoByEndpoint[$0]
            )
        })
    }
}
