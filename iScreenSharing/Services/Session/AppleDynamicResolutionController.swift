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
    private var mediaRestartPrepared = false
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
        // The host resets its media sender for every accepted display
        // configuration, even when the resulting canvas dimensions are
        // unchanged. The following layout response is the synchronization
        // point where the receive generation and media offer are replayed.
        mediaRestartPending = true
        mediaRestartPrepared = false
        do {
            try await sendMessage(configuration)
        } catch {
            combinedDisplaySelectionPending = false
            mediaRestartPending = false
            mediaRestartPrepared = false
            throw error
        }
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
            mediaRestartPending = true
            mediaRestartPrepared = false
        }
        guard mediaRestartPending else { return }
        if !mediaRestartPrepared {
            await prepareMediaRestart()
            mediaRestartPrepared = true
        }
        try await sendMessage(mediaConfiguration)
        mediaRestartPending = false
        mediaRestartPrepared = false
    }

    func receiveMediaCanvas(_ updatedCanvas: AppleCanvas) async {
        guard updatedCanvas.isUsable, updatedCanvas != canvas else { return }
        canvas = updatedCanvas
        mediaRestartPending = false
        mediaRestartPrepared = false
        await applyCanvas(updatedCanvas)
    }
}
