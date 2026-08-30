import Foundation
import enum ScreenSharingProtocol.AppleDisplayConfiguration
import enum ScreenSharingProtocol.AppleRFBMessages
import struct ScreenSharingProtocol.AppleCanvas
import struct ScreenSharingProtocol.AppleDisplayLayout
import struct ScreenSharingProtocol.AppleDynamicResolutionSize

actor AppleDynamicResolutionController {
    typealias SendMessage = @Sendable (Data) async throws -> Void
    typealias ApplyCanvas = @Sendable (AppleCanvas) async -> Void
    typealias PrepareMediaRestart = @Sendable () async -> Void

    private var canvas: AppleCanvas
    private let mediaConfiguration: Data
    private let sendMessage: SendMessage
    private let applyCanvas: ApplyCanvas
    private let prepareMediaRestart: PrepareMediaRestart
    private var mediaRestartPending = false
    private var hasReceivedInitialLayout = false
    private var combinedDisplaySelectionPending = false

    init(
        initialCanvas: AppleCanvas,
        mediaConfiguration: Data,
        sendMessage: @escaping SendMessage,
        applyCanvas: @escaping ApplyCanvas,
        prepareMediaRestart: @escaping PrepareMediaRestart
    ) {
        canvas = initialCanvas
        self.mediaConfiguration = mediaConfiguration
        self.sendMessage = sendMessage
        self.applyCanvas = applyCanvas
        self.prepareMediaRestart = prepareMediaRestart
    }

    func request(width: Int, height: Int, backingScale: Double = 2, hdr: Bool = false) async throws {
        try await request(
            displaySizes: [AppleDynamicResolutionSize(width: width, height: height)],
            backingScale: backingScale,
            hdr: hdr
        )
    }

    func requestFixedResolution() async throws {
        try await request(displaySizes: [.fixed1080p])
    }

    func request(
        displaySizes: [AppleDynamicResolutionSize],
        backingScale: Double = 2,
        hdr: Bool = false
    ) async throws {
        let configuration = try AppleDisplayConfiguration.message(
            displaySizes: displaySizes,
            backingScale: backingScale,
            hdr: hdr
        )
        combinedDisplaySelectionPending = displaySizes.count > 1
        try await sendMessage(configuration)
    }

    func receive(_ layout: AppleDisplayLayout) async throws {
        let receivedCanvas = layout.canvas(tileCount: canvas.tileCount)
        if combinedDisplaySelectionPending, layout.displays.count > 1 {
            try await sendMessage(AppleRFBMessages.selectCombinedDisplays)
            combinedDisplaySelectionPending = false
        }
        try await sendMessage(AppleRFBMessages.framebufferUpdateRequest())
        guard hasReceivedInitialLayout else {
            hasReceivedInitialLayout = true
            return
        }
        let updatedCanvas = receivedCanvas
        if updatedCanvas != canvas {
            canvas = updatedCanvas
            await applyCanvas(updatedCanvas)
            await prepareMediaRestart()
            mediaRestartPending = true
        }
        guard mediaRestartPending else { return }
        try await sendMessage(mediaConfiguration)
        mediaRestartPending = false
    }

    func receiveMediaCanvas(_ updatedCanvas: AppleCanvas) async {
        guard updatedCanvas.isUsable, updatedCanvas != canvas else { return }
        canvas = updatedCanvas
        mediaRestartPending = false
        await applyCanvas(updatedCanvas)
    }
}
