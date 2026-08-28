import Foundation

enum AppleVideoDecoderMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case videoProcessing
    case videoToolboxSynchronized
    case videoToolboxLowLatency = "videoToolbox"

    var id: Self { self }

    static let standardCases: [Self] = [
        .videoProcessing,
        .videoToolboxSynchronized,
    ]

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .videoProcessing: "VideoProcessing (VCP)"
        case .videoToolboxSynchronized: "VideoToolbox (Seamless)"
        case .videoToolboxLowLatency: "VideoToolbox (Low Latency)"
        }
    }

    var synchronizesTileFrames: Bool {
        self == .videoToolboxSynchronized
    }
}
