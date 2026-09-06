import class ScreenSharingProtocol.AppleEncryptedRecordLayer
import enum ScreenSharingProtocol.AppleEncryptedRecordError
import enum ScreenSharingProtocol.AppleRFBMessages
import struct ScreenSharingProtocol.AppleCanvas
import struct ScreenSharingProtocol.AppleMediaPorts
import struct ScreenSharingProtocol.AppleRecordKeys
import struct ScreenSharingProtocol.RFBServerInfo
import XCTest
@testable import iScreenSharing

final class AppleMediaNegotiatorTests: XCTestCase {
    func testConfigurationSendTimingExcludesEarlierStartupWrites() async throws {
        let timings = StartupTimingRecorder()
        let transport = NegotiationTimingTransport(
            chunks: try encryptedChunks([Self.canvasAnswer]),
            didSend: { timings.advance(by: 0.2) }
        )
        let session = try makeSession(transport: transport, trace: timings.makeTrace())
        defer { session.close() }
        _ = try await AppleMediaNegotiator().negotiate(session)
        XCTAssertEqual(try XCTUnwrap(timings.entry(.mediaConfigurationSent)?.durationMilliseconds), 200, accuracy: 0.001)
    }

    func testStartupTimingSeparatesMediaReadsParsingAndFinalizationWithoutChangingWireOrder() async throws {
        let timings = StartupTimingRecorder()
        let trace = timings.makeTrace()
        let unrelated = Data([0, 1, 2, 3])
        let transport = NegotiationTimingTransport(
            chunks: try encryptedChunks([unrelated, Self.canvasAnswer]),
            didRead: { timings.advance(by: 0.1) }
        )
        let receiver = NegotiationTimingReceiver(didStopPunching: { timings.advance(by: 0.3) })
        let session = try makeSession(transport: transport, receiver: receiver, trace: trace)
        defer { session.close() }

        let result = try await AppleMediaNegotiator().negotiate(session)

        XCTAssertEqual(result.canvas, AppleCanvas(width: 1920, height: 1080, tileCount: 4))
        XCTAssertEqual(result.pendingMessages, [unrelated])
        let peer = try makeRecordLayer()
        let sent = try transport.sentRecords.map { try peer.decrypt(Data($0.dropFirst(2))) }
        XCTAssertEqual(sent, AppleMediaNegotiator.framebufferStartupMessages() + [result.configuration])
        for index in 0..<2 {
            XCTAssertEqual(
                try XCTUnwrap(timings.entry(.mediaHeaderReceived, index: index)?.durationMilliseconds),
                100, accuracy: 0.001
            )
            XCTAssertEqual(
                try XCTUnwrap(timings.entry(.mediaBodyReceived, index: index)?.durationMilliseconds),
                100, accuracy: 0.001
            )
            XCTAssertEqual(timings.entry(.mediaRecordDecrypted, index: index)?.durationMilliseconds, 0)
        }
        XCTAssertNotNil(timings.entry(.mediaAnswerUnrelated, index: 0))
        XCTAssertEqual(timings.entry(.mediaCanvasesParsed, index: 0)?.count, 0)
        XCTAssertEqual(timings.entry(.mediaCanvasesParsed, index: 1)?.count, 1)
        XCTAssertEqual(
            try XCTUnwrap(timings.entry(.mediaNegotiationFinished)?.elapsedMilliseconds),
            700, accuracy: 0.001
        )
    }

    func testDetailedReadLimitAllowsNegotiationAndDoesNotTraceLaterControlReads() async throws {
        let timings = StartupTimingRecorder()
        let trace = timings.makeTrace()
        let unrelated = Data([0, 1, 2, 3])
        let controlMessage = Data([3, 0, 0, 0])
        let unrelatedCount = ConnectionStartupTrace.maximumDetailedMediaResponses + 5
        let transport = NegotiationTimingTransport(chunks: try encryptedChunks(
            Array(repeating: unrelated, count: unrelatedCount) + [Self.canvasAnswer, controlMessage]
        ))
        let session = try makeSession(transport: transport, trace: trace)
        defer { session.close() }

        let result = try await AppleMediaNegotiator().negotiate(session)
        XCTAssertEqual(result.pendingMessages.count, unrelatedCount)
        XCTAssertEqual(result.canvas.width, 1920)
        XCTAssertEqual(
            timings.entries.filter { $0.event.stage == .mediaReadStarted }.count,
            ConnectionStartupTrace.maximumDetailedMediaResponses
        )
        XCTAssertEqual(timings.entries.filter { $0.event.stage == .mediaReadLimitReached }.count, 1)
        XCTAssertNotNil(timings.entry(.mediaNegotiationFinished))
        let eventCount = timings.entries.count
        let received = try await session.receiveEncrypted()
        XCTAssertEqual(received, controlMessage)
        XCTAssertEqual(timings.entries.count, eventCount)
    }

    func testFailedStartupReadDoesNotReportBodyOrDecryptionCompletion() async throws {
        for header in [Data([0]), Data([0, 0]), Data([0, 17]), Data([0, 32])] {
            let timings = StartupTimingRecorder()
            let trace = timings.makeTrace()
            // The final case declares a complete block-aligned body, then EOFs.
            let session = try makeSession(
                transport: NegotiationTimingTransport(chunks: [header]), trace: trace
            )
            defer { session.close() }
            do {
                _ = try await session.receiveEncrypted(startupTiming: trace.beginMediaResponse())
                XCTFail("Expected invalid framing or EOF")
            } catch {
                if header.count < 2 || header == Data([0, 32]) {
                    XCTAssertTrue(error is NegotiationTimingTransport.ReadError)
                } else {
                    XCTAssertEqual(error as? AppleEncryptedRecordError, .invalidCiphertext)
                }
            }
            XCTAssertEqual(timings.entry(.mediaHeaderReceived, index: 0) != nil, header.count == 2)
            XCTAssertNil(timings.entry(.mediaBodyReceived, index: 0))
            XCTAssertNil(timings.entry(.mediaRecordDecrypted, index: 0))
        }
    }

    func testFailedRecordAuthenticationReportsBodyButNotDecryptionCompletion() async throws {
        let timings = StartupTimingRecorder()
        let trace = timings.makeTrace()
        var record = try makeRecordLayer().encrypt(Data([0, 1, 2, 3]))
        record[record.count - 1] ^= 1
        let session = try makeSession(
            transport: NegotiationTimingTransport(chunks: [
                Data(record.prefix(2)), Data(record.dropFirst(2)),
            ]),
            trace: trace
        )
        defer { session.close() }

        do {
            _ = try await session.receiveEncrypted(startupTiming: trace.beginMediaResponse())
            XCTFail("Expected corrupt encrypted record to be rejected")
        } catch {
            XCTAssertEqual(error as? AppleEncryptedRecordError, .authenticationFailed)
        }
        XCTAssertNotNil(timings.entry(.mediaBodyReceived, index: 0))
        XCTAssertNil(timings.entry(.mediaRecordDecrypted, index: 0))
    }

    // Existing ScreenSharingProtocol golden answer: one 1920 x 1080, four-tile canvas.
    private static let canvasAnswer = Data(base64Encoded:
        "AHByZWZpeGJwbGlzdDAw0QECXxAhYXZjTWVkaWFTdHJlYW1OZWdvdGlhdG9yTWVkaWFCbG9iTxASeJzT4lBo4NfYwWHAAgAK9AH+CAsvAAAAAAAAAQEAAAAAAAAAAwAAAAAAAAAAAAAAAAAAAER0YWls"
    )!

    private func makeRecordLayer() throws -> AppleEncryptedRecordLayer {
        AppleEncryptedRecordLayer(keys: try AppleRecordKeys(
            key: Data(0..<16), initializationVector: Data(16..<32)
        ))
    }

    private func encryptedChunks(_ messages: [Data]) throws -> [Data] {
        let layer = try makeRecordLayer()
        return try messages.flatMap { message in
            let record = try layer.encrypt(message)
            return [Data(record.prefix(2)), Data(record.dropFirst(2))]
        }
    }

    private func makeSession(
        transport: NegotiationTimingTransport,
        receiver: NegotiationTimingReceiver = NegotiationTimingReceiver(),
        trace: ConnectionStartupTrace
    ) throws -> RFBAuthenticatedSession {
        let session = RFBAuthenticatedSession(
            endpoint: try ConnectionEndpoint(host: "fixture.local"),
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(
                width: 1920, height: 1080,
                pixelFormat: Data(repeating: 0, count: 16), name: "Fixture"
            ),
            route: ManagedSessionRoute(
                control: transport,
                remoteAddress: try ResolvedRemoteAddress(numericHost: "127.0.0.1", port: 5900),
                sharingType: .highPerformance
            ) { _, _ in receiver },
            connectionTiming: trace
        )
        session.install(recordLayer: try makeRecordLayer())
        return session
    }

    func testFramebufferStartupRequestsInitialAndAutomaticUpdates() {
        XCTAssertEqual(
            AppleMediaNegotiator.framebufferStartupMessages(),
            [
                AppleRFBMessages.framebufferUpdateRequest(),
                AppleRFBMessages.autoFramebufferUpdate(),
            ]
        )
    }

    func testSelectsCombinedDesktopAfterDualDisplayLayoutBecomesAvailable() {
        XCTAssertNil(AppleMediaNegotiator.displaySelectionMessage(displayCount: 1))
        XCTAssertEqual(
            AppleMediaNegotiator.displaySelectionMessage(displayCount: 2),
            AppleRFBMessages.selectCombinedDisplays
        )
    }

    func testDualMediaStreamsKeepVirtualDisplayOrder() {
        XCTAssertEqual(
            AppleMediaStreamDisplayMapping.displayIndex(forMediaStreamIndex: 0, displayCount: 2),
            0
        )
        XCTAssertEqual(
            AppleMediaStreamDisplayMapping.displayIndex(forMediaStreamIndex: 1, displayCount: 2),
            1
        )
        XCTAssertEqual(
            AppleMediaStreamDisplayMapping.displayIndex(forMediaStreamIndex: 0, displayCount: 1),
            0
        )
    }

    func testDualMediaStreamsKeepCanvasInMediaStreamOrder() throws {
        let displayOne = AppleCanvas(width: 2560, height: 1440, tileCount: 4)
        let displayTwo = AppleCanvas(width: 1920, height: 1200, tileCount: 4)

        XCTAssertEqual(
            AppleMediaStreamDisplayMapping.canvas(
                forMediaStreamIndex: 0,
                from: [displayOne, displayTwo]
            ),
            displayOne
        )
        XCTAssertEqual(
            AppleMediaStreamDisplayMapping.canvas(
                forMediaStreamIndex: 1,
                from: [displayOne, displayTwo]
            ),
            displayTwo
        )
    }

}

private final class NegotiationTimingTransport: RFBTransport, @unchecked Sendable {
    enum ReadError: Error { case unexpectedRead }
    private let lock = NSLock()
    private var chunks: [Data]
    private var records = [Data]()
    private let didRead: @Sendable () -> Void
    private let didSend: @Sendable () -> Void

    init(chunks: [Data], didRead: @escaping @Sendable () -> Void = { }, didSend: @escaping @Sendable () -> Void = { }) {
        self.chunks = chunks
        self.didRead = didRead
        self.didSend = didSend
    }

    var sentRecords: [Data] { lock.withLock { records } }
    func start(timeout: Duration) async throws { }
    func cancel() { }
    func send(_ data: Data) async throws {
        lock.withLock { records.append(data) }
        didSend()
    }
    func receiveExactly(_ length: Int) async throws -> Data {
        let data = try lock.withLock {
            guard let data = chunks.first, data.count == length else {
                throw ReadError.unexpectedRead
            }
            chunks.removeFirst()
            return data
        }
        didRead()
        return data
    }
}

private final class NegotiationTimingReceiver: AppleMediaReceiving, @unchecked Sendable {
    private let didStopPunching: @Sendable () -> Void

    init(didStopPunching: @escaping @Sendable () -> Void = { }) {
        self.didStopPunching = didStopPunching
    }

    func startVideoDelivery(
        mediaStreamIndex: Int,
        on deliveryQueue: DispatchQueue,
        handler: @escaping AppleVideoDatagramHandler
    ) throws { }
    func stopVideoDelivery(mediaStreamIndex: Int) { }
    func videoReceiveBufferConfiguration(
        mediaStreamIndex: Int
    ) -> AppleMediaReceiveBufferConfiguration? { nil }
    func drainControlPackets() -> [Data] { [] }
    func sendControl(_ datagram: Data) throws { }
    func sendVideoControl(_ datagram: Data, mediaStreamIndex: Int) throws { }
    func configureRemotePorts(_ ports: AppleMediaPorts) throws { }
    func stopPunching() { didStopPunching() }
    func close() { }
}
