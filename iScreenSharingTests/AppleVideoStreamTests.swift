import Foundation
import struct ScreenSharingProtocol.AppleCanvas
import struct ScreenSharingProtocol.AppleMediaPorts
import XCTest
@testable import iScreenSharing

final class AppleVideoStreamTests: XCTestCase {
    func testStartupTimingRetainsFirstPacketAcrossMediaRestarts() async throws {
        let timings = StartupTimingRecorder()
        let receiver = VideoStreamReceiver()
        let stream = try AppleVideoStream(
            receiver: receiver,
            video: AppleVideoNegotiation(
                viewerKey: Data(0..<46), serverKey: Data(0..<46),
                synchronizationSource: 0x5566_7788,
                canvas: AppleCanvas(width: 8, height: 4, tileCount: 4),
                mediaStreamIndex: 0, displayIndex: 1
            ),
            connectionTiming: timings.makeTrace()
        )
        stream.start()
        defer { stream.close() }
        timings.setTime(0.125)
        try await receiver.deliver([Self.videoDatagram])
        await stream.prepareForMediaRestart()
        timings.setTime(1)
        try await receiver.deliver([Self.videoDatagram])

        XCTAssertEqual(timings.entry(.firstPacket, index: 1)?.elapsedMilliseconds, 125)
        XCTAssertEqual(timings.entry(.firstPacket, index: 1)?.durationMilliseconds, 125)
        XCTAssertEqual(timings.entries.filter { $0.event.stage == .firstPacket }.count, 1)
        XCTAssertNil(timings.entry(.firstPacket, index: 0))
    }

    func testReceiverReportsContinueAcrossConcurrentMediaRestarts() async throws {
        let receiver = VideoStreamReceiver()
        let stream = try AppleVideoStream(receiver: receiver, video: AppleVideoNegotiation(
            viewerKey: Data(0..<46),
            serverKey: Data(0..<46),
            synchronizationSource: 0x5566_7788,
            canvas: AppleCanvas(width: 8, height: 4, tileCount: 4),
            mediaStreamIndex: 0,
            displayIndex: 0
        ))
        stream.start()
        defer { stream.close() }

        // Both tasks use the production delivery/restart entry points. Rejected
        // packets keep the report-selection path active before a source arrives;
        // valid SRTP verifies that reports remain usable after each reset.
        async let delivery: Void = deliverDuringRestarts(receiver)
        for _ in 0..<300 {
            await stream.prepareForMediaRestart()
        }
        try await delivery

        await stream.prepareForMediaRestart()
        receiver.clearReports()
        try await receiver.deliver([Self.videoDatagram])
        XCTAssertEqual(receiver.reports.count, 1)
        XCTAssertEqual(receiver.reports.first?.prefix(8), Data([
            0x81, 0xc9, 0, 7, 0x55, 0x66, 0x77, 0x88,
        ]))
        XCTAssertEqual(receiver.reports.first?.count, 46)

        await stream.prepareForMediaRestart()
        try await receiver.deliver([Self.videoDatagram])
        XCTAssertEqual(receiver.reports.count, 2)
    }

    private func deliverDuringRestarts(_ receiver: VideoStreamReceiver) async throws {
        for _ in 0..<300 {
            try await receiver.deliver(Array(repeating: Data(), count: 16))
            try await receiver.deliver([Self.videoDatagram])
        }
    }

    // Existing SRTP golden vector: SSRC 0x11223344, sequence/timestamp zero.
    private static let videoDatagram = Data([
        0x80, 0xe0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x11, 0x22, 0x33, 0x44, 0x8e, 0x12, 0xaf, 0xed,
        0x43, 0x36, 0xc6, 0x40, 0xf7, 0x96, 0x80, 0xaa,
        0xb7, 0x79, 0x04,
    ])
}

final class VideoStreamReceiver: AppleMediaReceiving, @unchecked Sendable {
    private let lock = NSLock()
    private var delivery: (queue: DispatchQueue, handler: AppleVideoDatagramHandler)?
    private var sentReports = [Data]()

    var reports: [Data] { lock.withLock { sentReports } }

    func clearReports() {
        lock.withLock { sentReports.removeAll() }
    }

    func deliver(
        _ datagrams: [Data],
        arrivalTime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) async throws {
        let delivery = try lock.withLock { try XCTUnwrap(self.delivery) }
        await withCheckedContinuation { continuation in
            delivery.queue.async {
                for data in datagrams {
                    delivery.handler(AppleReceivedVideoDatagram(
                        data: data,
                        arrivalTime: arrivalTime
                    ))
                }
                continuation.resume()
            }
        }
    }

    func startVideoDelivery(
        mediaStreamIndex: Int,
        on deliveryQueue: DispatchQueue,
        handler: @escaping AppleVideoDatagramHandler
    ) throws {
        lock.withLock { delivery = (deliveryQueue, handler) }
    }

    func stopVideoDelivery(mediaStreamIndex: Int) {
        lock.withLock { delivery = nil }
    }

    func sendVideoControl(_ datagram: Data, mediaStreamIndex: Int) throws {
        guard datagram.prefix(2) == Data([0x81, 0xc9]) else { return }
        lock.withLock { sentReports.append(datagram) }
    }

    func videoReceiveBufferConfiguration(
        mediaStreamIndex: Int
    ) -> AppleMediaReceiveBufferConfiguration? { nil }
    func drainControlPackets() -> [Data] { [] }
    func sendControl(_ datagram: Data) throws { }
    func configureRemotePorts(_ ports: AppleMediaPorts) throws { }
    func stopPunching() { }
    func close() { }
}
