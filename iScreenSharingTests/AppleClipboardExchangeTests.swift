import AppKit
import enum ScreenSharingProtocol.AppleClipboardMessage
import struct ScreenSharingProtocol.AppleClipboardArchive
import XCTest
@testable import iScreenSharing

@MainActor
final class AppleClipboardExchangeTests: XCTestCase {
    func testManualGetRegistersSessionBeforeSendingAndAcceptsMatchingResponse() async throws {
        let pasteboard = makePasteboard()
        let service = AppleClipboardService(
            pasteboard: pasteboard,
            isSharingEnabled: false,
            isApplicationActive: { true }
        )
        let recorder = ClipboardExchangeRecorder()
        let exchange = makeExchange(service: service, recorder: recorder)

        try await exchange.requestRemoteClipboard()

        let manualRequests = await recorder.requests
        XCTAssertEqual(
            manualRequests,
            [ClipboardRequestRecord(promises: false, sessionID: 0x1234_5678)]
        )
        let response = try AppleClipboardMessage.send(
            archive: .text("remote manual clipboard"),
            sessionID: 0x1234_5678
        )
        let handledResponse = await exchange.receive(response)
        XCTAssertTrue(handledResponse)
        XCTAssertEqual(pasteboard.string(forType: .string), "remote manual clipboard")
    }

    func testAutomaticRemoteChangeUsesPromisesThenNativeZeroDataSession() async throws {
        let pasteboard = makePasteboard()
        let service = AppleClipboardService(
            pasteboard: pasteboard,
            isApplicationActive: { true }
        )
        service.start()
        service.setSessionWindow(UUID(), isKey: true)
        let recorder = ClipboardExchangeRecorder()
        let exchange = makeExchange(service: service, recorder: recorder)

        let handledNotification = await exchange.receive(remoteClipboardNotification(subtype: 2))
        XCTAssertTrue(handledNotification)
        let promiseRequests = await recorder.requests
        XCTAssertEqual(
            promiseRequests,
            [ClipboardRequestRecord(promises: true, sessionID: 0x1234_5678)]
        )

        let promises = try AppleClipboardMessage.send(
            archive: .text("remote"),
            promises: true,
            sessionID: 0x1234_5678
        )
        let handledPromises = await exchange.receive(promises)
        XCTAssertTrue(handledPromises)
        let dataRequests = await recorder.requests
        XCTAssertEqual(
            dataRequests,
            [
                ClipboardRequestRecord(promises: true, sessionID: 0x1234_5678),
                ClipboardRequestRecord(promises: false, sessionID: 0),
            ]
        )

        let data = try AppleClipboardMessage.send(
            archive: .text("remote automatic clipboard"),
            sessionID: 0
        )
        let handledData = await exchange.receive(data)
        XCTAssertTrue(handledData)
        XCTAssertEqual(pasteboard.string(forType: .string), "remote automatic clipboard")
        service.close()
    }

    func testRemoteDataRequestSendsCurrentLocalPasteboardOnceWithZeroSession() async throws {
        let pasteboard = makePasteboard()
        let advertised = expectation(description: "Local clipboard promises advertised")
        let service = AppleClipboardService(
            pasteboard: pasteboard,
            advertise: { _ in advertised.fulfill() },
            isApplicationActive: { true }
        )
        service.start()
        pasteboard.clearContents()
        pasteboard.setString("advertised", forType: .string)
        service.setSessionWindow(UUID(), isKey: true)
        await fulfillment(of: [advertised], timeout: 1)
        pasteboard.clearContents()
        pasteboard.setString("current", forType: .string)

        let recorder = ClipboardExchangeRecorder()
        let exchange = makeExchange(service: service, recorder: recorder)
        let request = remoteClipboardNotification(subtype: 3)

        let handledRequest = await exchange.receive(request)
        XCTAssertTrue(handledRequest)
        let sentArchives = await recorder.archives
        XCTAssertEqual(sentArchives.count, 1)
        let sentArchive = try XCTUnwrap(sentArchives.first)
        XCTAssertEqual(sentArchive.archive.preferredText, "current")
        XCTAssertFalse(sentArchive.promises)
        XCTAssertEqual(sentArchive.sessionID, 0)

        let handledDuplicate = await exchange.receive(request)
        XCTAssertTrue(handledDuplicate)
        let sentArchiveCount = await recorder.archives.count
        XCTAssertEqual(sentArchiveCount, 1)
        service.close()
    }

    func testDisabledSharingIgnoresAutomaticNotificationsButManualGetStillWorks() async throws {
        let pasteboard = makePasteboard()
        let service = AppleClipboardService(
            pasteboard: pasteboard,
            isSharingEnabled: false,
            isApplicationActive: { true }
        )
        service.start()
        service.setSessionWindow(UUID(), isKey: true)
        let recorder = ClipboardExchangeRecorder()
        let exchange = makeExchange(service: service, recorder: recorder)

        let handledNotification = await exchange.receive(remoteClipboardNotification(subtype: 2))
        XCTAssertTrue(handledNotification)
        let automaticRequests = await recorder.requests
        XCTAssertTrue(automaticRequests.isEmpty)

        try await exchange.requestRemoteClipboard()
        let manualRequests = await recorder.requests
        XCTAssertEqual(
            manualRequests,
            [ClipboardRequestRecord(promises: false, sessionID: 0x1234_5678)]
        )
        service.close()
    }

    func testExpiredManualResponseIsIgnoredAndDoesNotBlockAnotherRequest() async throws {
        let pasteboard = makePasteboard()
        let service = AppleClipboardService(pasteboard: pasteboard)
        let recorder = ClipboardExchangeRecorder()
        let clock = ClipboardExchangeTestClock()
        let exchange = makeExchange(
            service: service,
            recorder: recorder,
            uptimeNanoseconds: { clock.value },
            requestLifetimeNanoseconds: 120
        )

        try await exchange.requestRemoteClipboard()
        clock.value = 121
        let staleResponse = try AppleClipboardMessage.send(
            archive: .text("stale"),
            sessionID: 0x1234_5678
        )
        let handledStaleResponse = await exchange.receive(staleResponse)

        XCTAssertTrue(handledStaleResponse)
        XCTAssertNil(pasteboard.string(forType: .string))

        try await exchange.requestRemoteClipboard()
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testExpiredResponseKeepsConsumingItsContinuationsWithoutInstallingClipboard() async throws {
        let pasteboard = makePasteboard()
        let service = AppleClipboardService(pasteboard: pasteboard)
        let recorder = ClipboardExchangeRecorder()
        let clock = ClipboardExchangeTestClock()
        let exchange = makeExchange(
            service: service,
            recorder: recorder,
            uptimeNanoseconds: { clock.value },
            requestLifetimeNanoseconds: 120
        )
        try await exchange.requestRemoteClipboard()
        let message = try AppleClipboardMessage.send(archive: .text("expired"), sessionID: 0x1234_5678)
        let acceptedHeader = await exchange.receive(Data(message.prefix(16)))
        XCTAssertTrue(acceptedHeader)
        clock.value = 121

        let acceptedEmpty = await exchange.receiveContinuation(Data())
        let acceptedFirstPayload = await exchange.receiveContinuation(message.subdata(in: 16..<18))
        let acceptedLastPayload = await exchange.receiveContinuation(Data(message.dropFirst(18)))

        XCTAssertFalse(acceptedEmpty)
        XCTAssertTrue(acceptedFirstPayload)
        XCTAssertTrue(acceptedLastPayload)
        XCTAssertNil(pasteboard.string(forType: .string))
        let claimedNextMessage = await exchange.receiveContinuation(Data([0, 0, 0, 0]))
        XCTAssertFalse(claimedNextMessage)
        try await exchange.requestRemoteClipboard()
        let acceptedFresh = await exchange.receive(
            try AppleClipboardMessage.send(archive: .text("fresh"), sessionID: 0x1234_5678)
        )
        XCTAssertTrue(acceptedFresh)
        XCTAssertEqual(pasteboard.string(forType: .string), "fresh")
    }

    func testSupersedingRequestPreservesOldResponseBoundaryAndAcceptsNewResponse() async throws {
        let pasteboard = makePasteboard()
        let service = AppleClipboardService(pasteboard: pasteboard)
        let recorder = ClipboardExchangeRecorder()
        let clock = ClipboardExchangeTestClock()
        let exchange = makeExchange(
            service: service,
            recorder: recorder,
            makeSessionID: { 0x1234_5678 + UInt32(clock.value) }
        )
        try await exchange.requestRemoteClipboard()
        let oldResponse = try AppleClipboardMessage.send(archive: .text("obsolete"), sessionID: 0x1234_5678)
        let acceptedHeader = await exchange.receive(Data(oldResponse.prefix(16)))
        XCTAssertTrue(acceptedHeader)
        clock.value = 1

        try await exchange.requestRemoteClipboard()
        let acceptedContinuation = await exchange.receiveContinuation(Data(oldResponse.dropFirst(16)))

        XCTAssertTrue(acceptedContinuation)
        XCTAssertNil(pasteboard.string(forType: .string))
        let acceptedNewResponse = await exchange.receive(
            try AppleClipboardMessage.send(archive: .text("current"), sessionID: 0x1234_5679)
        )
        XCTAssertTrue(acceptedNewResponse)
        XCTAssertEqual(pasteboard.string(forType: .string), "current")
    }

    private func makeExchange(
        service: AppleClipboardService,
        recorder: ClipboardExchangeRecorder,
        makeSessionID: @escaping @Sendable () -> UInt32 = { 0x1234_5678 },
        uptimeNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        requestLifetimeNanoseconds: UInt64 = 120_000_000_000
    ) -> AppleClipboardExchange {
        AppleClipboardExchange(
            clipboard: service,
            makeSessionID: makeSessionID,
            uptimeNanoseconds: uptimeNanoseconds,
            requestLifetimeNanoseconds: requestLifetimeNanoseconds,
            sendRequest: { promises, sessionID in
                await recorder.recordRequest(promises: promises, sessionID: sessionID)
            },
            sendArchive: { archive, promises, sessionID in
                await recorder.recordArchive(
                    archive,
                    promises: promises,
                    sessionID: sessionID
                )
            }
        )
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("clipboard-exchange-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    private func remoteClipboardNotification(subtype: UInt16) -> Data {
        var message = Data(repeating: 0, count: 8)
        message[0] = 0x14
        message.writeUInt16BE(subtype, at: 6)
        return message
    }
}

private struct ClipboardRequestRecord: Equatable, Sendable {
    let promises: Bool
    let sessionID: UInt32
}

private struct ClipboardArchiveRecord: Equatable, Sendable {
    let archive: AppleClipboardArchive
    let promises: Bool
    let sessionID: UInt32
}

private actor ClipboardExchangeRecorder {
    private(set) var requests = [ClipboardRequestRecord]()
    private(set) var archives = [ClipboardArchiveRecord]()

    func recordRequest(promises: Bool, sessionID: UInt32) {
        requests.append(ClipboardRequestRecord(promises: promises, sessionID: sessionID))
    }

    func recordArchive(
        _ archive: AppleClipboardArchive,
        promises: Bool,
        sessionID: UInt32
    ) {
        archives.append(ClipboardArchiveRecord(
            archive: archive,
            promises: promises,
            sessionID: sessionID
        ))
    }
}

private final class ClipboardExchangeTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: UInt64 = 0

    var value: UInt64 {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}
