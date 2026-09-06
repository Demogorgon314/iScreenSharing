import CoreGraphics
import Foundation
import struct ScreenSharingProtocol.AppleDynamicResolutionSize

enum MobileResolutionPreset: String, CaseIterable, Identifiable {
    case fitScreen
    case hd
    case workspace
    case fullHD

    var id: Self { self }

    var title: String {
        switch self {
        case .fitScreen: "Fit to Screen"
        case .hd: "1280 × 720"
        case .workspace: "1440 × 900"
        case .fullHD: "1920 × 1080"
        }
    }

    func size(for viewport: CGSize) -> AppleDynamicResolutionSize? {
        switch self {
        case .fitScreen:
            AppleDynamicResolutionSize.normalized(viewport: viewport)
        case .hd:
            AppleDynamicResolutionSize(width: 1280, height: 720)
        case .workspace:
            AppleDynamicResolutionSize(width: 1440, height: 900)
        case .fullHD:
            .fixed1080p
        }
    }
}

struct MobileResolutionPreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func preset(for endpoint: ConnectionEndpoint) -> MobileResolutionPreset {
        guard let value = defaults.string(forKey: key(for: endpoint)),
              let preset = MobileResolutionPreset(rawValue: value) else { return .fitScreen }
        return preset
    }

    func save(_ preset: MobileResolutionPreset, for endpoint: ConnectionEndpoint) {
        defaults.set(preset.rawValue, forKey: key(for: endpoint))
    }

    private func key(for endpoint: ConnectionEndpoint) -> String {
        "MobileResolutionPreset.\(endpoint.url.absoluteString)"
    }
}
