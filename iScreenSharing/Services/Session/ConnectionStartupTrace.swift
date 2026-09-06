import Foundation
import OSLog
import QuartzCore

/// One sign-in attempt, retained by its session after the async activation ends.
/// All timestamps use the local monotonic Core Animation clock, including Metal
/// presentedTime. Events on parallel branches have explicit interval anchors.
final class ConnectionStartupTrace: @unchecked Sendable {
    @TaskLocal static var current: ConnectionStartupTrace?

    enum Stage: String, Sendable {
        case signInStarted, routeStarted, resolutionStarted, resolutionReady
        case tcpStarted, tcpReady, tcpFailed, routeReady
        case bannerReadStarted, bannerReceived, clientVersionSendStarted, clientVersionSent
        case securityCountReadStarted, securityCountReceived
        case securityTypesReadStarted, securityTypesReceived
        case versionReady, authenticationReady, serverInitReady
        case encryptionStarted, encryptionReady, mediaStarted, mediaRouteReady
        case mediaOfferReady, mediaStartupMessagesSent, mediaLayoutWaitStarted, mediaLayoutReady
        case mediaConfigurationSendStarted, mediaNegotiationFinished
        case mediaConfigurationSent, mediaRetry, mediaReady
        case mediaReadStarted, mediaHeaderReceived, mediaBodyReceived, mediaRecordDecrypted
        case mediaResponseReceived, mediaPortsConfigured, mediaCanvasParseStarted, mediaCanvasesParsed
        case mediaAnswerUnrelated, mediaAnswerDegenerate, mediaAnswerCanvas, mediaReadLimitReached
        case videoStarted, firstPacket, parameterSetsReady, selectionThreshold, sourcesSelected
        case decoderPreparationStarted, decoderPreparationReady, decoderPreparationFailed, decoderPreparationReused
        case decoderStarted, decoderReady, firstDecoded, firstFramePublished
        case audioStarted, audioReady, audioUnavailable, activationReady
        case windowStarted, windowOrdered, firstPresented
        case failed, cancelled, closed
    }

    struct Event: Hashable, Sendable {
        let stage: Stage
        // Display index for video/window events; attempt index for TCP/retry events;
        // sequential encrypted-record index for media response events.
        let index: Int?

        init(_ stage: Stage, index: Int? = nil) {
            self.stage = stage
            self.index = index
        }
    }

    struct MediaResponse: Sendable {
        fileprivate let trace: ConnectionStartupTrace
        let index: Int

        func record(_ stage: Stage, since anchor: Stage? = nil, count: Int? = nil) {
            trace.record(
                stage, index: index,
                since: anchor.map { Event($0, index: index) }, count: count
            )
        }
    }

    struct Entry: Sendable {
        let connectionID: UUID
        let event: Event
        let elapsedMilliseconds: Double
        let anchor: Event?
        let durationMilliseconds: Double?
        let count: Int?

        var logLine: String {
            var fields = [
                "[CONNECTION-TIMING] id=\(connectionID.uuidString)",
                "stage=\(event.stage.rawValue)",
                "elapsed_ms=\(milliseconds(elapsedMilliseconds))",
            ]
            if let index = event.index { fields.append("index=\(index)") }
            if let anchor, let durationMilliseconds {
                fields.append("since=\(anchor.stage.rawValue)")
                fields.append("duration_ms=\(milliseconds(durationMilliseconds))")
            }
            if let count { fields.append("count=\(count)") }
            return fields.joined(separator: " ")
        }

        private func milliseconds(_ value: Double) -> String {
            String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
    }

    private static let logger = Logger(
        subsystem: "com.wangkai.iShareScreen", category: "ConnectionTiming"
    )
    let connectionID = UUID()
    private let clock: @Sendable () -> TimeInterval
    private let emit: @Sendable (Entry) -> Void
    private let startedAt: TimeInterval
    private let lock = NSLock()
    private var timestamps = [Event: TimeInterval]()
    private var hasFinished = false
    private var mediaResponseCount = 0

    // A diagnostic limit only: negotiation continues reading after this cap.
    static let maximumDetailedMediaResponses = 64

    static func makeIfEnabled() -> ConnectionStartupTrace? {
        guard ProcessInfo.processInfo.environment["ISHARESCREEN_CONNECTION_DIAGNOSTICS"] == "1"
        else { return nil }
        return ConnectionStartupTrace()
    }

    init(
        clock: @escaping @Sendable () -> TimeInterval = { CACurrentMediaTime() },
        emit: (@Sendable (Entry) -> Void)? = nil
    ) {
        self.clock = clock
        self.emit = emit ?? { entry in
            Self.logger.notice("\(entry.logLine, privacy: .public)")
        }
        startedAt = clock()
        record(.signInStarted, at: startedAt)
    }

    /// Records the first observation only, even across decoder/media restarts.
    /// A supplied timestamp is the event time, not the callback delivery time.
    func record(
        _ stage: Stage,
        index: Int? = nil,
        since anchor: Event? = nil,
        at timestamp: TimeInterval? = nil,
        count: Int? = nil
    ) {
        let entry = lock.withLock { () -> Entry? in
            let event = Event(stage, index: index)
            guard !hasFinished, timestamps[event] == nil else { return nil }
            let time = timestamp ?? clock()
            guard time.isFinite, time >= startedAt else { return nil }
            timestamps[event] = time
            let duration = anchor.flatMap { timestamps[$0] }.flatMap { start in
                time >= start ? (time - start) * 1_000 : nil
            }
            return Entry(
                connectionID: connectionID,
                event: event,
                elapsedMilliseconds: (time - startedAt) * 1_000,
                anchor: anchor,
                durationMilliseconds: duration,
                count: count
            )
        }
        if let entry { emit(entry) }
    }

    func beginMediaResponse() -> MediaResponse? {
        let response = lock.withLock { () -> MediaResponse? in
            guard !hasFinished, mediaResponseCount < Self.maximumDetailedMediaResponses else {
                return nil
            }
            defer { mediaResponseCount += 1 }
            return MediaResponse(trace: self, index: mediaResponseCount)
        }
        if let response {
            response.record(.mediaReadStarted)
        } else {
            record(.mediaReadLimitReached, count: Self.maximumDetailedMediaResponses)
        }
        return response
    }

    func finish(_ stage: Stage) {
        precondition(stage == .failed || stage == .cancelled || stage == .closed)
        // Record and close atomically, so a late decoder/drawable callback cannot
        // create a successful startup event after termination.
        let entry = lock.withLock { () -> Entry? in
            guard !hasFinished else { return nil }
            hasFinished = true
            return Entry(
                connectionID: connectionID,
                event: Event(stage),
                elapsedMilliseconds: (clock() - startedAt) * 1_000,
                anchor: nil,
                durationMilliseconds: nil,
                count: nil
            )
        }
        if let entry { emit(entry) }
    }
}
