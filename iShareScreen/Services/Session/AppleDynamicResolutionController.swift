import Foundation

actor AppleDynamicResolutionController {
    typealias SendMessage = @Sendable (Data) async throws -> Void
    typealias ApplyCanvas = @Sendable (AppleCanvas) async -> Void

    private var canvas: AppleCanvas
    private let mediaConfiguration: Data
    private let sendMessage: SendMessage
    private let applyCanvas: ApplyCanvas
    private var mediaReofferPending = false
    private var hasReceivedInitialLayout = false
    private var combinedDisplaySelectionPending = false

    init(
        initialCanvas: AppleCanvas,
        mediaConfiguration: Data,
        sendMessage: @escaping SendMessage,
        applyCanvas: @escaping ApplyCanvas
    ) {
        canvas = initialCanvas
        self.mediaConfiguration = mediaConfiguration
        self.sendMessage = sendMessage
        self.applyCanvas = applyCanvas
    }

    func request(width: Int, height: Int, backingScale: Double = 2, hdr: Bool = false) async throws {
        try await request(
            displaySizes: [AppleDynamicResolutionSize(width: width, height: height)],
            backingScale: backingScale,
            hdr: hdr
        )
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
        try await sendMessage(AppleRFBMessages.framebufferUpdateRequest())
    }

    func receive(_ layout: AppleDisplayLayout) async throws {
        if combinedDisplaySelectionPending, layout.displays.count > 1 {
            try await sendMessage(AppleRFBMessages.selectCombinedDisplays)
            combinedDisplaySelectionPending = false
        }
        try await sendMessage(AppleRFBMessages.framebufferUpdateRequest())
        guard hasReceivedInitialLayout else {
            hasReceivedInitialLayout = true
            return
        }
        let updatedCanvas = layout.canvas(tileCount: canvas.tileCount)
        if updatedCanvas != canvas {
            canvas = updatedCanvas
            await applyCanvas(updatedCanvas)
            mediaReofferPending = true
        }
        guard mediaReofferPending else { return }
        try await sendMessage(mediaConfiguration)
        mediaReofferPending = false
    }

    func receiveMediaCanvas(_ updatedCanvas: AppleCanvas) async {
        guard updatedCanvas.isUsable, updatedCanvas != canvas else { return }
        canvas = updatedCanvas
        mediaReofferPending = false
        await applyCanvas(updatedCanvas)
    }
}
