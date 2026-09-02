import Foundation
import enum ScreenSharingProtocol.AppleFramebufferUpdate
import enum ScreenSharingProtocol.AppleMediaConfiguration
import enum ScreenSharingProtocol.AppleMediaOffer
import enum ScreenSharingProtocol.AppleRFBMessages
import struct ScreenSharingProtocol.AppleCanvas
import struct ScreenSharingProtocol.AppleMediaKeys
import struct ScreenSharingProtocol.AppleMediaOffers

struct AppleMediaNegotiationEnvironment: Sendable {
    let randomBytes: @Sendable (Int) throws -> Data
    let randomUInt32: @Sendable () throws -> UInt32
    let timestamp: @Sendable () -> UInt64
    let uuid: @Sendable () -> UUID
    let operatingSystemVersion: String

    static let system = Self(
        randomBytes: { try Cryptography.randomBytes(count: $0) },
        randomUInt32: { try Cryptography.randomUInt32() },
        timestamp: {
            UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        },
        uuid: { UUID() },
        operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString
    )
}

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
    private let environment: AppleMediaNegotiationEnvironment

    init(environment: AppleMediaNegotiationEnvironment = .system) {
        self.environment = environment
    }

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
        let offers = try makeOffer()
        let secondaryOffers = displayCount > 1 ? try makeOffer() : nil
        let keys = try makeKeys(includeSecondaryVideo: secondaryOffers != nil)
        let configuration = try AppleMediaConfiguration.message(
            audioOffer: offers.audio,
            videoOffer: offers.video,
            secondaryVideoOffer: secondaryOffers?.video,
            keys: keys,
            callID: environment.uuid()
        )

        for message in Self.framebufferStartupMessages() {
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
        if let displaySelection = Self.displaySelectionMessage(displayCount: displayCount) {
            // Native establishes the global screen after DisplayInfo2 is complete. The pointer
            // coordinates below share that combined backing space, so the server must not retain
            // an individual-display selection from display setup or a previous transition.
            try await session.sendEncrypted(displaySelection)
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

    private func makeOffer() throws -> AppleMediaOffers {
        try AppleMediaOffer.create(
            randomUInt32: environment.randomUInt32,
            timestamp: environment.timestamp,
            uuid: environment.uuid,
            operatingSystemVersion: environment.operatingSystemVersion
        )
    }

    private func makeKeys(includeSecondaryVideo: Bool) throws -> AppleMediaKeys {
        try AppleMediaKeys(
            audioViewer: environment.randomBytes(AppleMediaKeys.blobLength),
            audioServer: environment.randomBytes(AppleMediaKeys.blobLength),
            videoViewer: environment.randomBytes(AppleMediaKeys.blobLength),
            videoServer: environment.randomBytes(AppleMediaKeys.blobLength),
            secondaryVideoViewer: includeSecondaryVideo
                ? environment.randomBytes(AppleMediaKeys.blobLength) : nil,
            secondaryVideoServer: includeSecondaryVideo
                ? environment.randomBytes(AppleMediaKeys.blobLength) : nil
        )
    }

    static func framebufferStartupMessages() -> [Data] {
        [
            AppleRFBMessages.framebufferUpdateRequest(),
            AppleRFBMessages.autoFramebufferUpdate(),
        ]
    }

    static func displaySelectionMessage(displayCount: Int) -> Data? {
        displayCount > 1 ? AppleRFBMessages.selectCombinedDisplays : nil
    }

}

enum AppleMediaNegotiationError: LocalizedError, Equatable {
    case missingCanvas

    var errorDescription: String? {
        "The remote Mac did not provide a usable screen canvas."
    }
}
