import Foundation
import Network
import OSLog

enum BonjourBrowseUpdate: Equatable, Sendable {
    case searching
    case results([ConnectionEndpoint])
    case failed(String)
}

protocol BonjourBrowsing: Sendable {
    func updates() -> AsyncStream<BonjourBrowseUpdate>
}

struct BonjourBrowser: BonjourBrowsing {
    private static let logger = Logger(subsystem: "com.wangkai.iShareScreen", category: "Bonjour")
    private let queue = DispatchQueue(label: "com.isharescreen.bonjour-browser")

    func updates() -> AsyncStream<BonjourBrowseUpdate> {
        AsyncStream { continuation in
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let browser = NWBrowser(
                for: .bonjour(type: "_rfb._tcp", domain: "local."),
                using: parameters
            )
            let lock = NSLock()
            var endpoints = [ConnectionEndpoint]()

            continuation.yield(.searching)
            browser.browseResultsChangedHandler = { results, _ in
                let values = Self.connectionEndpoints(from: results)
                Self.logger.debug("Bonjour results changed: \(values.count)")
                lock.withBonjourLock { endpoints = values }
                continuation.yield(.results(values))
            }
            browser.stateUpdateHandler = { state in
                Self.logger.debug("Bonjour browser state: \(String(describing: state), privacy: .public)")
                switch state {
                case .ready:
                    continuation.yield(.results(lock.withBonjourLock { endpoints }))
                case .failed(let error):
                    continuation.yield(.failed(error.localizedDescription))
                    continuation.finish()
                case .cancelled:
                    continuation.finish()
                default:
                    break
                }
            }
            continuation.onTermination = { _ in browser.cancel() }
            browser.start(queue: queue)
        }
    }

    static func connectionEndpoint(from endpoint: NWEndpoint) -> ConnectionEndpoint? {
        guard case let .service(name, type, domain, _) = endpoint,
              let service = try? BonjourServiceEndpoint(name: name, type: type, domain: domain) else {
            return nil
        }
        return ConnectionEndpoint(bonjourService: service)
    }

    private static func connectionEndpoints(
        from results: Set<NWBrowser.Result>
    ) -> [ConnectionEndpoint] {
        let unique = Set(results.compactMap { connectionEndpoint(from: $0.endpoint) })
        return unique.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }
}

private extension NSLock {
    func withBonjourLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
