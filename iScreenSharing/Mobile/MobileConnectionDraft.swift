import Foundation
import struct ScreenSharingProtocol.AppleRemoteDeviceInfo

struct MobileConnectionDraft: Equatable {
    var address = ""
    var name = ""
    var username = ""
    var port = "5900"
    private var originalEndpoint: ConnectionEndpoint?
    private var discoveredDeviceInfo: AppleRemoteDeviceInfo?

    init(address: String) { self.address = address }

    init(connection: SavedConnection? = nil) {
        guard let connection else { return }
        originalEndpoint = connection.endpoint
        discoveredDeviceInfo = connection.deviceInfo
        address = connection.endpoint.host
        name = connection.name
        username = connection.preferredUsername
        port = String(connection.endpoint.port)
    }

    func endpoint() throws -> ConnectionEndpoint {
        guard let portNumber = UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines)), portNumber > 0 else {
            throw ConnectionEndpointError.invalidPort
        }
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if let originalEndpoint, originalEndpoint.host == address, originalEndpoint.port == portNumber {
            return originalEndpoint
        }
        let parsed = try ConnectionEndpoint(address)
        return try ConnectionEndpoint(host: parsed.host, port: portNumber == 5900 ? parsed.port : portNumber)
    }

    @MainActor
    func save(in store: ConnectionStore, editing original: SavedConnection? = nil) throws -> SavedConnection {
        let endpoint = try endpoint()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let connection = original ?? store.networkConfiguration(
            for: endpoint, deviceInfo: endpoint == originalEndpoint ? discoveredDeviceInfo : nil
        )
        try store.update(
            connection, name: trimmedName.isEmpty ? endpoint.displayName : trimmedName,
            endpoint: endpoint, preferredUsername: username,
            sharingType: .highPerformance, virtualDisplayCount: .one
        )
        return store.connection(for: endpoint) ?? connection
    }
}
