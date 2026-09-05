import AppKit
import Combine
import Foundation
import enum ScreenSharingProtocol.AppleClipboardMessage
import enum ScreenSharingProtocol.AppleCursorUpdate
import enum ScreenSharingProtocol.AppleFileTransferMessage
import class ScreenSharingProtocol.AppleEncryptedRecordLayer
import struct ScreenSharingProtocol.AppleCanvas
import struct ScreenSharingProtocol.AppleClipboardArchive
import struct ScreenSharingProtocol.AppleClipboardFlavor
import struct ScreenSharingProtocol.AppleClipboardItem
import struct ScreenSharingProtocol.AppleRecordKeys
import struct ScreenSharingProtocol.RFBServerInfo
import XCTest
@testable import iScreenSharing

@MainActor
final class AppleControlMessageServiceTests: XCTestCase {
    func testClipboardContinuationsAreNotRoutedAsOtherControlMessages() async throws {
        let vectors: [(seed: UInt64, prefix: UInt8)] = [
            (57, 0x00), (784, 0x1e), (842, 0x20), (332, 0x22),
        ]
        for vector in vectors {
            let fileTransfer = AppleFileTransferService(
                remoteName: "Test Mac",
                history: AppleFileTransferHistory(),
                send: { _ in }
            )
            let recorder = ControlDispatchRecorder()
            let harness = try makeHarness(
                receiveCursorUpdate: { await recorder.recordCursor($0) },
                receiveFileTransferMessage: { fragment in
                    let accepted = await fileTransfer.receive(fragment)
                    if accepted { await recorder.recordFileFragment(fragment) }
                    return accepted
                }
            )
            defer { harness.manager.disconnect(harness.endpoint) }
            let serverLayer = try makeRecordLayer()
            let sessionID = try await requestClipboard(harness, serverLayer: serverLayer)
            let archive = binaryClipboard(seed: vector.seed)
            let message = try AppleClipboardMessage.send(archive: archive, sessionID: sessionID)
            // Confirm a valid native-sized continuation independently of routing
            // and the separate multi-output-block codec bug.
            XCTAssertEqual(try AppleClipboardMessage.archive(from: message), archive)
            let fragments = AppleClipboardMessage.fragments(of: message)
            XCTAssertEqual(fragments[2].first, vector.prefix)
            let fileURL = URL(fileURLWithPath: "/remote/Folder/file.txt")
            let drag = try AppleFileTransferMessage.beginDrop(fileURL: fileURL, sessionID: 0x1234)
            let cursor = cursorSelection(id: 7)
            harness.transport.enqueueReceived(try serverLayer.encrypt(fragments + [drag, cursor]))

            harness.service.start()
            await fulfillment(of: [harness.transport.readStarted], timeout: 1)

            XCTAssertEqual(harness.pasteboard.data(forType: .png), archive.items[0].flavors[0].value)
            XCTAssertEqual(fileTransfer.remoteDrag.drag?.sourcePaths, [fileURL.path])
            let fileFragments = await recorder.fileFragments
            let cursorUpdates = await recorder.cursorUpdates
            XCTAssertEqual(fileFragments, [drag])
            XCTAssertEqual(cursorUpdates, [.select(id: 7)])
            XCTAssertNotNil(harness.manager.session(for: harness.endpoint))
            await fileTransfer.close()
            harness.manager.disconnect(harness.endpoint)
            await fulfillment(of: [harness.transport.cancelled], timeout: 1)
        }
    }

    func testFileTransferContinuationBeginningWithClipboardTypeKeepsItsOwner() async throws {
        let fileTransfer = AppleFileTransferService(
            remoteName: "Test Mac",
            history: AppleFileTransferHistory(),
            send: { _ in }
        )
        let recorder = ControlDispatchRecorder()
        let harness = try makeHarness(
            receiveCursorUpdate: { await recorder.recordCursor($0) },
            receiveFileTransferMessage: { await fileTransfer.receive($0) }
        )
        defer { harness.manager.disconnect(harness.endpoint) }
        let serverLayer = try makeRecordLayer()
        let sessionID = try await requestClipboard(harness, serverLayer: serverLayer)
        let fileURL = URL(fileURLWithPath: "/remote/Folder/file.txt")
        let drag = try AppleFileTransferMessage.beginDrop(fileURL: fileURL, sessionID: 0x1f00_0001)
        let continuation = Data(drag.dropFirst(4))
        XCTAssertEqual(continuation.first, 0x1f)
        let clipboard = try AppleClipboardMessage.send(archive: .text("after file transfer"), sessionID: sessionID)
        let records = [Data(drag.prefix(4)), continuation]
            + AppleClipboardMessage.fragments(of: clipboard)
            + [cursorSelection(id: 7)]
        harness.transport.enqueueReceived(try serverLayer.encrypt(records))

        harness.service.start()
        await fulfillment(of: [harness.transport.readStarted], timeout: 1)

        XCTAssertEqual(fileTransfer.remoteDrag.drag?.sourcePaths, [fileURL.path])
        XCTAssertEqual(harness.pasteboard.string(forType: .string), "after file transfer")
        let cursorUpdates = await recorder.cursorUpdates
        XCTAssertEqual(cursorUpdates, [.select(id: 7)])
        await fileTransfer.close()
        harness.manager.disconnect(harness.endpoint)
        await fulfillment(of: [harness.transport.cancelled], timeout: 1)
    }

    func testMalformedClipboardHeaderDoesNotConsumeFollowingControlMessages() async throws {
        let recorder = ControlDispatchRecorder()
        let harness = try makeHarness(receiveCursorUpdate: { await recorder.recordCursor($0) })
        defer { harness.manager.disconnect(harness.endpoint) }
        var header = Data(repeating: 0, count: 16)
        header[0] = 0x1f
        header.writeUInt32BE(UInt32(AppleClipboardMessage.maximumPayloadLength + 1), at: 12)
        harness.transport.enqueueReceived(try makeRecordLayer().encrypt([header, cursorSelection(id: 7)]))

        harness.service.start()
        await fulfillment(of: [harness.transport.readStarted], timeout: 1)

        let cursorUpdates = await recorder.cursorUpdates
        XCTAssertEqual(cursorUpdates, [.select(id: 7)])
        XCTAssertNotNil(harness.manager.session(for: harness.endpoint))
        harness.manager.disconnect(harness.endpoint)
        await fulfillment(of: [harness.transport.cancelled], timeout: 1)
    }

    func testTransportFailureClosesInstalledSession() async throws {
        let harness = try makeHarness()
        defer { harness.manager.disconnect(harness.endpoint) }

        let removed = sessionRemovalExpectation(
            manager: harness.manager,
            endpoint: harness.endpoint
        )
        harness.service.start()
        await fulfillment(of: [harness.transport.readStarted], timeout: 1)

        harness.transport.failPendingRead()

        await fulfillment(
            of: [removed.expectation, harness.transport.cancelled],
            timeout: 1
        )
        XCTAssertNil(harness.manager.session(for: harness.endpoint))
        withExtendedLifetime(removed.observation) {}
    }

    func testInvalidEncryptedRecordClosesInstalledSession() async throws {
        let harness = try makeHarness()
        defer { harness.manager.disconnect(harness.endpoint) }

        let removed = sessionRemovalExpectation(
            manager: harness.manager,
            endpoint: harness.endpoint
        )
        harness.service.start()
        await fulfillment(of: [harness.transport.readStarted], timeout: 1)

        harness.transport.resumePendingRead(returning: Data([0, 1]))

        await fulfillment(
            of: [removed.expectation, harness.transport.cancelled],
            timeout: 1
        )
        XCTAssertNil(harness.manager.session(for: harness.endpoint))
        withExtendedLifetime(removed.observation) {}
    }

    private func makeHarness(
        receiveCursorUpdate: @escaping @Sendable (AppleCursorUpdate) async -> Void = { _ in },
        receiveFileTransferMessage: @escaping @Sendable (Data) async -> Bool = { _ in false }
    ) throws -> ControlMessageHarness {
        let endpoint = try ConnectionEndpoint("example.local")
        let remoteAddress = try ResolvedRemoteAddress(
            numericHost: "127.0.0.1",
            port: endpoint.port
        )
        let transport = ControlledControlTransport(
            readStarted: expectation(description: "Control read started"),
            cancelled: expectation(description: "Control transport cancelled")
        )
        let session = RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: remoteAddress,
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(
                width: 1920,
                height: 1080,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Test Mac"
            ),
            transport: transport
        )
        session.install(recordLayer: try makeRecordLayer())
        let input = AppleInputController(
            session: session,
            canvas: AppleCanvas(width: 1920, height: 1080, tileCount: 4)
        )
        session.install(inputController: input)
        let pasteboard = NSPasteboard(name: .init("control-message-\(UUID().uuidString)"))
        let clipboard = AppleClipboardService(
            pasteboard: pasteboard,
            isApplicationActive: { true }
        )
        let service = AppleControlMessageService(
            session: session,
            input: input,
            clipboard: clipboard,
            pendingMessages: [],
            receiveCursorUpdate: receiveCursorUpdate,
            receiveFileTransferMessage: receiveFileTransferMessage
        )
        session.install(
            controlMessageService: service,
            clipboardService: clipboard
        )
        let manager = SessionManager()
        manager.install(session)
        return ControlMessageHarness(
            endpoint: endpoint,
            transport: transport,
            service: service,
            manager: manager,
            pasteboard: pasteboard
        )
    }

    private func makeRecordLayer() throws -> AppleEncryptedRecordLayer {
        AppleEncryptedRecordLayer(keys: try AppleRecordKeys(
            key: Data(repeating: 0x11, count: 16),
            initializationVector: Data(repeating: 0x22, count: 16)
        ))
    }

    private func requestClipboard(
        _ harness: ControlMessageHarness,
        serverLayer: AppleEncryptedRecordLayer
    ) async throws -> UInt32 {
        try await harness.service.requestRemoteClipboard()
        let record = try XCTUnwrap(harness.transport.sentMessages.first)
        let request = try XCTUnwrap(AppleClipboardMessage.request(
            from: serverLayer.decrypt(Data(record.dropFirst(2)))
        ))
        return request.sessionID
    }

    private func cursorSelection(id: UInt32) -> Data {
        var message = Data([0, 0, 0, 1])
        message.append(Data(repeating: 0, count: 8))
        message.appendInt32BE(0x450)
        message.appendUInt32BE(id)
        message.appendUInt32BE(0)
        return message
    }

    private func binaryClipboard(seed: UInt64) -> AppleClipboardArchive {
        var state = seed
        let bytes = Data((0..<50_000).map { _ -> UInt8 in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        })
        return AppleClipboardArchive(items: [AppleClipboardItem(flavors: [
            AppleClipboardFlavor(type: "public.png", aliases: [], value: bytes),
        ])])
    }

    private func sessionRemovalExpectation(
        manager: SessionManager,
        endpoint: ConnectionEndpoint
    ) -> SessionRemovalObservation {
        let expectation = expectation(description: "Session removed")
        let observation = manager.$sessions.dropFirst().sink { sessions in
            if sessions[endpoint] == nil {
                expectation.fulfill()
            }
        }
        return SessionRemovalObservation(
            expectation: expectation,
            observation: observation
        )
    }
}

private struct ControlMessageHarness {
    let endpoint: ConnectionEndpoint
    let transport: ControlledControlTransport
    let service: AppleControlMessageService
    let manager: SessionManager
    let pasteboard: NSPasteboard
}

private struct SessionRemovalObservation {
    let expectation: XCTestExpectation
    let observation: AnyCancellable
}

private actor ControlDispatchRecorder {
    private(set) var fileFragments = [Data]()
    private(set) var cursorUpdates = [AppleCursorUpdate]()

    func recordFileFragment(_ fragment: Data) { fileFragments.append(fragment) }
    func recordCursor(_ cursor: AppleCursorUpdate) { cursorUpdates.append(cursor) }
}

private enum ControlledControlTransportError: Error {
    case connectionClosed
}

private final class ControlledControlTransport: RFBTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pendingRead: CheckedContinuation<Data, Error>?
    private var receiveData = Data()
    private var sent = [Data]()
    let readStarted: XCTestExpectation
    let cancelled: XCTestExpectation

    init(readStarted: XCTestExpectation, cancelled: XCTestExpectation) {
        self.readStarted = readStarted
        self.cancelled = cancelled
    }

    func start(timeout: Duration) async throws {}

    var sentMessages: [Data] { lock.withLock { sent } }

    func send(_ data: Data) async throws {
        lock.withLock { sent.append(data) }
    }

    func enqueueReceived(_ data: Data) {
        lock.withLock {
            precondition(pendingRead == nil)
            receiveData.append(data)
        }
    }

    func receiveExactly(_ length: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if receiveData.count >= length {
                let data = Data(receiveData.prefix(length))
                receiveData.removeFirst(length)
                lock.unlock()
                continuation.resume(returning: data)
                return
            }
            precondition(pendingRead == nil)
            pendingRead = continuation
            lock.unlock()
            readStarted.fulfill()
        }
    }

    func resumePendingRead(returning data: Data) {
        takePendingRead()?.resume(returning: data)
    }

    func failPendingRead() {
        takePendingRead()?.resume(throwing: ControlledControlTransportError.connectionClosed)
    }

    func cancel() {
        cancelled.fulfill()
        failPendingRead()
    }

    private func takePendingRead() -> CheckedContinuation<Data, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let continuation = pendingRead
        pendingRead = nil
        return continuation
    }
}
