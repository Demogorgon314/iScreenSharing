import CoreGraphics
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
