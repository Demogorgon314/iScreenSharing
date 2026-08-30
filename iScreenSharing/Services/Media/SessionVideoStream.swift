import Combine
import Foundation
import struct ScreenSharingProtocol.AppleCanvas

class SessionVideoStream: ObservableObject, @unchecked Sendable {
    enum State: Equatable {
        case preparing
        case streaming
        case failed(String)
        case stopped
    }

    @Published var state: State = .preparing
    @Published var canvas: AppleCanvas
    let frames: AppleVideoFrameStore
    let performance: AppleVideoPerformanceMonitor
    let displayIndex: Int

    init(canvas: AppleCanvas, displayIndex: Int, tileCount: Int) {
        self.canvas = canvas
        self.displayIndex = displayIndex
        frames = AppleVideoFrameStore()
        performance = AppleVideoPerformanceMonitor(tileCount: tileCount)
    }

    var decodedFrameCount: Int { 0 }
    var presentsFramesOnlyOnDisplayLink: Bool { false }

    func start() { }
    func close() { }
    func setDecoderMode(_ mode: AppleVideoDecoderMode) { }
    func setDisplayDrivenFrameRequestsEnabled(_ enabled: Bool) { }
    func requestFrameForDisplay() { }
}
