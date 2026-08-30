import Foundation

public struct AppleRemoteDeviceInfo: Codable, Equatable, Hashable, Sendable {
    public let modelIdentifier: String
    public let deviceColor: String?
    public let enclosureColor: String?
    public let enclosureRGBColorComponents: UInt32?
    public let housingColor: UInt32?
    public let flags: UInt32

    public init(
        modelIdentifier: String,
        deviceColor: String? = nil,
        enclosureColor: String? = nil,
        enclosureRGBColorComponents: UInt32? = nil,
        housingColor: UInt32? = nil,
        flags: UInt32 = 0
    ) {
        self.modelIdentifier = modelIdentifier
        self.deviceColor = deviceColor?.nilIfEmpty
        self.enclosureColor = enclosureColor?.nilIfEmpty
        self.enclosureRGBColorComponents = enclosureRGBColorComponents
        self.housingColor = housingColor
        self.flags = flags
    }

    public var enclosureColorIndex: Int32? {
        Self.colorIndex(from: deviceColor)
            ?? Self.colorIndex(from: enclosureColor)
    }

    private static func colorIndex(from value: String?) -> Int32? {
        guard let value else { return nil }
        return Int32(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
