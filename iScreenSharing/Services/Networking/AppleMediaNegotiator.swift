import Foundation

enum AppleMediaStreamDisplayMapping {
    static func displayIndex(forMediaStreamIndex mediaStreamIndex: Int, displayCount: Int) -> Int {
        mediaStreamIndex
    }

    static func canvas(
        forMediaStreamIndex mediaStreamIndex: Int,
        from displayCanvases: [AppleCanvas]
    ) -> AppleCanvas? {
        guard displayCanvases.indices.contains(mediaStreamIndex) else { return nil }
        return displayCanvases[mediaStreamIndex]
    }
}

struct AppleVideoNegotiation: Equatable, Sendable {
    let viewerKey: Data
    let serverKey: Data
    let synchronizationSource: UInt32
    let canvas: AppleCanvas
    let mediaStreamIndex: Int
    let displayIndex: Int
}

struct AppleMediaNegotiationResult: Equatable, Sendable {
    let keys: AppleMediaKeys
    let canvas: AppleCanvas
    let videoSynchronizationSource: UInt32
    let configuration: Data
    let pendingMessages: [Data]
    let videos: [AppleVideoNegotiation]

    init(
        keys: AppleMediaKeys,
        canvas: AppleCanvas,
        videoSynchronizationSource: UInt32,
        configuration: Data,
        pendingMessages: [Data],
        videos: [AppleVideoNegotiation]? = nil
    ) {
        self.keys = keys
        self.canvas = canvas
        self.videoSynchronizationSource = videoSynchronizationSource
        self.configuration = configuration
        self.pendingMessages = pendingMessages
        self.videos = videos ?? [AppleVideoNegotiation(
            viewerKey: keys.videoViewer,
            serverKey: keys.videoServer,
            synchronizationSource: videoSynchronizationSource,
            canvas: canvas,
            mediaStreamIndex: 0,
            displayIndex: 0
        )]
    }
}

protocol AppleMediaNegotiating: Sendable {
    func negotiate(
        _ session: RFBAuthenticatedSession,
        displayCount: Int
    ) async throws -> AppleMediaNegotiationResult
}

struct AppleMediaNegotiator: AppleMediaNegotiating {
    private static let retryLimit = 16

    func negotiate(
        _ session: RFBAuthenticatedSession,
        displayCount: Int = 1
    ) async throws -> AppleMediaNegotiationResult {
        let receiver = try await session.openHighPerformanceMedia(displayCount: displayCount)
        session.install(mediaReceiver: receiver)
        do {
            return try await negotiate(session, receiver: receiver, displayCount: displayCount)
        } catch {
            receiver.close()
            throw error
        }
    }

    private func negotiate(
        _ session: RFBAuthenticatedSession,
        receiver: any AppleMediaReceiving,
        displayCount: Int
    ) async throws -> AppleMediaNegotiationResult {
        let offers = try AppleMediaOffer.create()
        let secondaryOffers = displayCount > 1 ? try AppleMediaOffer.create() : nil
        let keys = try AppleMediaKeys.random(includeSecondaryVideo: secondaryOffers != nil)
        let configuration = try AppleMediaConfiguration.message(
            audioOffer: offers.audio,
            videoOffer: offers.video,
            secondaryVideoOffer: secondaryOffers?.video,
            keys: keys
        )

        for message in try Self.framebufferStartupMessages(displayCount: displayCount) {
            try await session.sendEncrypted(message)
        }

        var pendingMessages = [Data]()
        if displayCount > 1 {
            while !pendingMessages.contains(where: {
                AppleFramebufferUpdate.displayLayouts(from: $0)
                    .contains(where: { $0.displays.count >= displayCount })
            }) {
                pendingMessages.append(try await session.receiveEncrypted())
            }
        }
        try await session.sendEncrypted(configuration)

        var retryCount = 0
        var negotiatedCanvases = [AppleCanvas]()
        var configuredExplicitPorts = false
        negotiationLoop: while retryCount <= Self.retryLimit {
            let response = try await session.receiveEncrypted()
            if !configuredExplicitPorts,
               let ports = AppleMediaConfiguration.ports(from: response),
               ports.videos.count == displayCount {
                try receiver.configureRemotePorts(ports)
                configuredExplicitPorts = true
            }
            let canvases = AppleMediaConfiguration.canvases(from: response)
            if !canvases.isEmpty {
                negotiatedCanvases.append(contentsOf: canvases)
                let expectedCanvasCount = secondaryOffers == nil ? 1 : 2
                guard negotiatedCanvases.count >= expectedCanvasCount else { continue }
                guard let firstCanvas = AppleMediaStreamDisplayMapping.canvas(
                    forMediaStreamIndex: 0,
                    from: negotiatedCanvases
                ) else { continue }
                var videos = [AppleVideoNegotiation(
                    viewerKey: keys.videoViewer,
                    serverKey: keys.videoServer,
                    synchronizationSource: offers.videoSynchronizationSource,
                    canvas: firstCanvas,
                    mediaStreamIndex: 0,
                    displayIndex: AppleMediaStreamDisplayMapping.displayIndex(
                        forMediaStreamIndex: 0,
                        displayCount: displayCount
                    )
                )]
                if let secondaryOffers,
                   let viewerKey = keys.secondaryVideoViewer,
                   let serverKey = keys.secondaryVideoServer,
                   let secondCanvas = AppleMediaStreamDisplayMapping.canvas(
                       forMediaStreamIndex: 1,
                       from: negotiatedCanvases
                   ) {
                    videos.append(AppleVideoNegotiation(
                        viewerKey: viewerKey,
                        serverKey: serverKey,
                        synchronizationSource: secondaryOffers.videoSynchronizationSource,
                        canvas: secondCanvas,
                        mediaStreamIndex: 1,
                        displayIndex: AppleMediaStreamDisplayMapping.displayIndex(
                            forMediaStreamIndex: 1,
                            displayCount: displayCount
                        )
                    ))
                }
                let primaryCanvas = videos.first(where: { $0.displayIndex == 0 })?.canvas
                    ?? videos[0].canvas
                let result = AppleMediaNegotiationResult(
                    keys: keys,
                    canvas: primaryCanvas,
                    videoSynchronizationSource: offers.videoSynchronizationSource,
                    configuration: configuration,
                    pendingMessages: pendingMessages,
                    videos: videos
                )
                receiver.stopPunching()
                return result
            }
            switch AppleMediaConfiguration.answerStatus(from: response) {
            case .canvas:
                continue
            case .unrelated:
                pendingMessages.append(response)
                continue
            case .degenerate:
                guard retryCount < Self.retryLimit else { break negotiationLoop }
                retryCount += 1
                try await Task.sleep(for: .milliseconds(200))
                try await session.sendEncrypted(configuration)
            }
        }
        throw AppleMediaNegotiationError.missingCanvas
    }

    static func framebufferStartupMessages() throws -> [Data] {
        try framebufferStartupMessages(displayCount: 1)
    }

    static func framebufferStartupMessages(displayCount: Int) throws -> [Data] {
        [
            try AppleRFBMessages.setEncodings(),
            AppleRFBMessages.framebufferUpdateRequest(),
            AppleRFBMessages.autoFramebufferUpdate(),
        ]
    }

}

enum AppleMediaNegotiationError: LocalizedError, Equatable {
    case missingCanvas

    var errorDescription: String? {
        "The remote Mac did not provide a usable screen canvas."
    }
}
