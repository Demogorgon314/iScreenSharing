import Foundation
import struct ScreenSharingProtocol.AppleRemoteDeviceInfo

struct SavedConnection: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var endpoint: ConnectionEndpoint
    var name: String
    var lastConnectedAt: Date
    var preferredUsername: String
    var sharingType: ScreenSharingType
    var standardQuality: StandardRFBQuality
    var virtualDisplayCount: VirtualDisplayCount
    var usesSharedClipboard: Bool?
    var scalesToFit: Bool?
    var deviceInfo: AppleRemoteDeviceInfo?

    init(
        id: UUID = UUID(),
        endpoint: ConnectionEndpoint,
        name: String? = nil,
        lastConnectedAt: Date = .now,
        preferredUsername: String = "",
        sharingType: ScreenSharingType = .highPerformance,
        standardQuality: StandardRFBQuality = .high,
        virtualDisplayCount: VirtualDisplayCount = .one,
        usesSharedClipboard: Bool? = nil,
        scalesToFit: Bool? = nil,
        deviceInfo: AppleRemoteDeviceInfo? = nil
    ) {
        self.id = id
        self.endpoint = endpoint
        self.name = name ?? endpoint.displayName
        self.lastConnectedAt = lastConnectedAt
        self.preferredUsername = preferredUsername
        self.sharingType = sharingType
        self.standardQuality = standardQuality
        self.virtualDisplayCount = virtualDisplayCount
        self.usesSharedClipboard = usesSharedClipboard
        self.scalesToFit = scalesToFit
        self.deviceInfo = deviceInfo
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        endpoint = try container.decode(ConnectionEndpoint.self, forKey: .endpoint)
        name = try container.decode(String.self, forKey: .name)
        lastConnectedAt = try container.decode(Date.self, forKey: .lastConnectedAt)
        preferredUsername = try container.decodeIfPresent(String.self, forKey: .preferredUsername) ?? ""
        sharingType = try container.decodeIfPresent(ScreenSharingType.self, forKey: .sharingType)
            ?? .highPerformance
        standardQuality = try container.decodeIfPresent(StandardRFBQuality.self, forKey: .standardQuality)
            ?? .high
        virtualDisplayCount = try container.decodeIfPresent(VirtualDisplayCount.self, forKey: .virtualDisplayCount)
            ?? .one
        usesSharedClipboard = try container.decodeIfPresent(Bool.self, forKey: .usesSharedClipboard)
        scalesToFit = try container.decodeIfPresent(Bool.self, forKey: .scalesToFit)
        deviceInfo = try container.decodeIfPresent(AppleRemoteDeviceInfo.self, forKey: .deviceInfo)
    }
}

enum StandardRFBQuality: String, Codable, CaseIterable, Sendable {
    case high
    case balanced
    case medium
    case lowBandwidth

    var title: String {
        switch self {
        case .high: "High (32-bit color)"
        case .balanced: "Balanced (Reduced Color)"
        case .medium: "Medium (16-level grayscale)"
        case .lowBandwidth: "Low Bandwidth (Black & White, 1-bit)"
        }
    }

    var level: Double {
        switch self {
        case .lowBandwidth: 0
        case .medium: 1
        case .balanced: 2
        case .high: 3
        }
    }

    init(level: Double) {
        switch Int(level.rounded()) {
        case ...0: self = .lowBandwidth
        case 1: self = .medium
        case 2: self = .balanced
        default: self = .high
        }
    }
}

enum ScreenSharingType: String, Codable, CaseIterable, Sendable {
    case standard
    case highPerformance

    var title: String {
        switch self {
        case .standard: "Standard"
        case .highPerformance: "High Performance"
        }
    }
}

enum VirtualDisplayCount: Int, Codable, CaseIterable, Sendable {
    case one = 1
    case two = 2

    var title: String { "\(rawValue) Virtual Display\(rawValue == 1 ? "" : "s")" }
}
