import Foundation
import ScreenSharingProtocol

struct RFBProbeResult: Equatable, Sendable {
    let serverVersion: RFBVersion
    let securityTypes: [RFBSecurityType]
}

protocol RFBProbing: Sendable {
    func probe(_ endpoint: ConnectionEndpoint) async throws -> RFBProbeResult
}

struct RFBProbeService: RFBProbing {
    func probe(_ endpoint: ConnectionEndpoint) async throws -> RFBProbeResult {
        let transport = NWConnectionTransport(endpoint: endpoint)
        defer { transport.cancel() }

        try await transport.start()
        let banner = try await transport.receiveExactly(RFBProtocol.bannerLength)
        let version = try RFBProtocol.parseVersion(banner)
        try await transport.send(RFBProtocol.appleVersion)
        let countData = try await transport.receiveExactly(1)
        let count = try RFBProtocol.parseSecurityTypeCount(countData)
        let types = try RFBProtocol.parseSecurityTypes(
            try await transport.receiveExactly(count),
            expectedCount: count
        )
        return RFBProbeResult(serverVersion: version, securityTypes: types)
    }
}
