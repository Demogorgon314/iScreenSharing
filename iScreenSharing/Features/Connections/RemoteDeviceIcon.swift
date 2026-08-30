import AppKit
import struct ScreenSharingProtocol.AppleRemoteDeviceInfo
import SwiftUI
import UniformTypeIdentifiers

struct RemoteDeviceIcon: View {
    let deviceInfo: AppleRemoteDeviceInfo?
    let size: CGFloat

    init(deviceInfo: AppleRemoteDeviceInfo?, size: CGFloat = 32) {
        self.deviceInfo = deviceInfo
        self.size = size
    }

    var body: some View {
        Image(nsImage: RemoteHardwareIcon.image(for: deviceInfo))
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel("Remote Mac")
    }
}

@MainActor
enum RemoteHardwareIcon {
    private static let deviceModelTag = UTTagClass(
        rawValue: "com.apple.device-model-code"
    )
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 25
        return cache
    }()

    static func image(for deviceInfo: AppleRemoteDeviceInfo?) -> NSImage {
        guard let deviceInfo,
              let type = contentType(for: deviceInfo) else { return fallbackImage }
        let model = deviceInfo.modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)

        let cacheKey = "\(model)|\(deviceInfo.enclosureColorIndex.map(String.init) ?? "-")" as NSString
        if let image = cache.object(forKey: cacheKey) {
            return image
        }

        let image = NSWorkspace.shared.icon(for: type)
        cache.setObject(image, forKey: cacheKey)
        return image
    }

    static func contentType(for deviceInfo: AppleRemoteDeviceInfo) -> UTType? {
        let model = deviceInfo.modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }
        return declaredType(for: model, colorIndex: deviceInfo.enclosureColorIndex)
            ?? declaredType(for: model, colorIndex: nil)
    }

    private static func declaredType(for model: String, colorIndex: Int32?) -> UTType? {
        let tag = colorIndex.map { "\(model)@ECOLOR=\($0)" } ?? model
        guard let type = UTType(tag: tag, tagClass: deviceModelTag, conformingTo: nil),
              type.isDeclared else { return nil }
        return type
    }

    private static var fallbackImage: NSImage {
        NSImage(
            systemSymbolName: "desktopcomputer",
            accessibilityDescription: "Remote Mac"
        ) ?? NSWorkspace.shared.icon(for: .item)
    }
}
