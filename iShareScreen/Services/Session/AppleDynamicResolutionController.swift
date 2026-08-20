import Foundation

actor AppleDynamicResolutionController {
    typealias SendMessage = @Sendable (Data) async throws -> Void
    typealias ApplyCanvas = @Sendable (AppleCanvas) async -> Void

    private var canvas: AppleCanvas
    private let mediaConfiguration: Data
    private let sendMessage: SendMessage
    private let applyCanvas: ApplyCanvas
    private var mediaReofferPending = false

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
        let configuration = try AppleDisplayConfiguration.message(
            width: width,
            height: height,
            backingScale: backingScale,
            hdr: hdr
        )
        try await sendMessage(configuration)
        try await sendMessage(AppleRFBMessages.framebufferUpdateRequest())
    }

    func receive(_ layout: AppleDisplayLayout) async throws {
        try await sendMessage(AppleRFBMessages.framebufferUpdateRequest())
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
