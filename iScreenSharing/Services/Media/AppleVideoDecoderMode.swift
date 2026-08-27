import Foundation

enum AppleVideoDecoderMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case videoProcessing
    case videoToolboxSynchronized
    case videoToolboxLowLatency = "videoToolbox"

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .videoProcessing: "VideoProcessing (VCP)"
        case .videoToolboxSynchronized: "VideoToolbox (Synchronized)"
        case .videoToolboxLowLatency: "VideoToolbox (Low Latency)"
        }
    }

    var synchronizesTileFrames: Bool {
        self == .videoToolboxSynchronized
    }
}
