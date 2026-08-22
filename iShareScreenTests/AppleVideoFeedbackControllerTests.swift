import XCTest
@testable import iShareScreen

final class AppleVideoFeedbackControllerTests: XCTestCase {
    func testSendsEncryptedNACKForEachSource() throws {
        let sender = FeedbackSenderSpy()
        let controller = try AppleVideoFeedbackController(
            sender: sender,
            keyBlob: Data(0..<46),
            synchronizationSource: 0x1122_3344
        )

        try controller.sendNACKs([0x5566_7788: [10, 11, 13, 30]])

        XCTAssertEqual(
            sender.datagrams.map(\.hex),
            ["80c9000111223344ea6540af06680fabb3ce005aa192a9c2d9138ea18000000005039c4d56c23bf9e2ba"]
        )
    }

    func testRateLimitsKeyFrameRequestsPerSource() throws {
        let sender = FeedbackSenderSpy()
        var currentTime: TimeInterval = 100
        let controller = try AppleVideoFeedbackController(
            sender: sender,
            keyBlob: Data(0..<46),
            synchronizationSource: 1,
            now: { currentTime }
        )

        try controller.requestKeyFrame(for: 2)
        try controller.requestKeyFrame(for: 2)
        try controller.requestKeyFrame(for: 3)
        currentTime += 1
        try controller.requestKeyFrame(for: 2)

        XCTAssertEqual(sender.datagrams.count, 3)
    }

    func testPropagatesTransportFailure() throws {
        let sender = FeedbackSenderSpy(error: TestError.failed)
        let controller = try AppleVideoFeedbackController(
            sender: sender,
            keyBlob: Data(0..<46),
            synchronizationSource: 1
        )
        XCTAssertThrowsError(try controller.sendReceiverReport())
    }

    func testSendsNativeReceiverReportAsOneSRTCPDatagram() throws {
        let sender = FeedbackSenderSpy()
        let controller = try AppleVideoFeedbackController(
            sender: sender,
            keyBlob: Data(0..<46),
            synchronizationSource: 0x1122_3344
        )
        let report = AppleRTPReceptionReport(
            source: 0x5566_7788,
            fractionLost: 0,
            cumulativePacketsLost: 0,
            extendedHighestSequence: 42,
            interarrivalJitter: 3,
            lastSenderReport: 0,
            delaySinceLastSenderReport: 0
        )

        try controller.sendReceiverReport(report: report)

        XCTAssertEqual(sender.datagrams.count, 1)
        XCTAssertEqual(sender.datagrams[0].count, 46)
    }

    func testSendsStandaloneRateControlPacket() throws {
        let sender = FeedbackSenderSpy()
        let controller = try AppleVideoFeedbackController(
            sender: sender,
            keyBlob: Data(0..<46),
            synchronizationSource: 0x1122_3344
        )

        try controller.sendRateControl(mediaControlInfo: Data(0..<20))

        XCTAssertEqual(sender.datagrams.count, 1)
        XCTAssertEqual(sender.datagrams[0].count, 46)
    }

    func testRejectsInvalidRateControlPayload() throws {
        let controller = try AppleVideoFeedbackController(
            sender: FeedbackSenderSpy(),
            keyBlob: Data(0..<46),
            synchronizationSource: 1
        )

        XCTAssertThrowsError(
            try controller.sendRateControl(mediaControlInfo: Data(repeating: 0, count: 19))
        ) { error in
            XCTAssertEqual(error as? AppleVideoFeedbackError, .invalidRateControlPayload)
        }
    }

    func testConcurrentFeedbackPreservesSRTCPIndexSendOrder() throws {
        let sender = FeedbackSenderSpy()
        let controller = try AppleVideoFeedbackController(
            sender: sender,
            keyBlob: Data(0..<46),
            synchronizationSource: 1
        )
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "feedback-test", attributes: .concurrent)

        for _ in 0..<100 {
            group.enter()
            queue.async {
                try? controller.sendReceiverReport()
                group.leave()
            }
        }
        group.wait()

        let indexes = try sender.datagrams.map { datagram in
            try datagram.uint32BE(at: datagram.count - 14) & 0x7fff_ffff
        }
        XCTAssertEqual(indexes, Array(UInt32(0)..<UInt32(100)))
    }

    func testAcknowledgesEachLongTermReferenceOnce() throws {
        let sender = FeedbackSenderSpy()
        let controller = try AppleVideoFeedbackController(
            sender: sender,
            keyBlob: Data(0..<46),
            synchronizationSource: 0x1122_3344
        )

        try controller.acknowledgeLongTermReference(frameID: 7)
        try controller.acknowledgeLongTermReference(frameID: 7)
        try controller.acknowledgeLongTermReference(frameID: 8)

        XCTAssertEqual(sender.datagrams.count, 2)
    }
}

private final class FeedbackSenderSpy: AppleMediaControlSending, @unchecked Sendable {
    private let lock = NSLock()
    private var sentDatagrams = [Data]()
    private let error: Error?

    init(error: Error? = nil) { self.error = error }

    var datagrams: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return sentDatagrams
    }

    func sendControl(_ datagram: Data) throws {
        if let error { throw error }
        lock.lock()
        defer { lock.unlock() }
        sentDatagrams.append(datagram)
    }
}

private enum TestError: Error { case failed }

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
