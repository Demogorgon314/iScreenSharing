import AppKit
import Foundation
import ScreenSharingProtocol
import XCTest
@testable import iScreenSharing

@MainActor
final class RemoteVideoCanvasKeyboardTests: XCTestCase {
    func testRemoteCanvasAcceptsActivationClick() throws {
        let view = RemoteVideoCanvasNSView(
            canvas: AppleCanvas(width: 1_920, height: 1_080, tileCount: 4),
            frames: AppleVideoFrameStore(),
            input: nil,
            cursors: nil,
            displayScale: AppleVideoDisplayScale(),
            synchronizesPresentation: true,
            sourceRect: nil,
            inputMapping: nil,
            inputCoordinatesAreDisplayLocal: false,
            inputDisplayID: nil
        )
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 100, y: 100),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))

        XCTAssertTrue(view.acceptsFirstMouse(for: event))
    }

    func testRemoteCanvasConsumesCommandKeyEquivalentBeforeApplicationMenu() throws {
        let canvas = AppleCanvas(width: 1_920, height: 1_080, tileCount: 4)
        let input = AppleInputController(
            session: try makeSession(),
            canvas: canvas
        )
        let view = RemoteVideoCanvasNSView(
            canvas: canvas,
            frames: AppleVideoFrameStore(),
            input: input,
            cursors: nil,
            displayScale: AppleVideoDisplayScale(),
            synchronizesPresentation: true,
            sourceRect: nil,
            inputMapping: nil,
            inputCoordinatesAreDisplayLocal: false,
            inputDisplayID: nil
        )
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "+",
            charactersIgnoringModifiers: "=",
            isARepeat: false,
            keyCode: 24
        ))

        XCTAssertTrue(view.performKeyEquivalent(with: event))
    }

    func testCanvasWithoutRemoteInputLeavesKeyEquivalentForApplication() throws {
        let view = RemoteVideoCanvasNSView(
            canvas: AppleCanvas(width: 1_920, height: 1_080, tileCount: 4),
            frames: AppleVideoFrameStore(),
            input: nil,
            cursors: nil,
            displayScale: AppleVideoDisplayScale(),
            synchronizesPresentation: true,
            sourceRect: nil,
            inputMapping: nil,
            inputCoordinatesAreDisplayLocal: false,
            inputDisplayID: nil
        )
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "n",
            charactersIgnoringModifiers: "n",
            isARepeat: false,
            keyCode: 45
        ))

        XCTAssertFalse(view.performKeyEquivalent(with: event))
    }

    func testCanvasStopsConsumingKeyEquivalentsWhenControlIsRemoved() throws {
        let canvas = AppleCanvas(width: 1_920, height: 1_080, tileCount: 4)
        let view = RemoteVideoCanvasNSView(
            canvas: canvas,
            frames: AppleVideoFrameStore(),
            input: AppleInputController(session: try makeSession(), canvas: canvas),
            cursors: nil,
            displayScale: AppleVideoDisplayScale(),
            synchronizesPresentation: true,
            sourceRect: nil,
            inputMapping: nil,
            inputCoordinatesAreDisplayLocal: false,
            inputDisplayID: nil
        )
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "w",
            charactersIgnoringModifiers: "w",
            isARepeat: false,
            keyCode: 13
        ))

        view.updateInput(nil)

        XCTAssertFalse(view.performKeyEquivalent(with: event))
    }

    func testRemoteFileDragArrivalRepostsCurrentEvent() async throws {
        let service = AppleFileTransferService(
            remoteName: "Remote Mac",
            history: AppleFileTransferHistory(),
            send: { _ in }
        )
        var repostCount = 0
        let view = RemoteVideoCanvasNSView(
            canvas: AppleCanvas(width: 1_920, height: 1_080, tileCount: 4),
            frames: AppleVideoFrameStore(),
            input: nil,
            fileTransfer: service,
            cursors: nil,
            displayScale: AppleVideoDisplayScale(),
            synchronizesPresentation: true,
            sourceRect: nil,
            inputMapping: nil,
            inputCoordinatesAreDisplayLocal: false,
            inputDisplayID: nil,
            repostCurrentEvent: { repostCount += 1 }
        )
        let archive = AppleClipboardArchive(items: [
            AppleClipboardItem(flavors: [
                AppleClipboardFlavor(
                    type: "public.file-url",
                    aliases: [],
                    value: Data("file:///remote/file.txt".utf8)
                )
            ])
        ])
        var message = try AppleClipboardMessage.send(archive: archive, sessionID: 7)
        message[0] = 0x20

        let accepted = await service.receive(message)

        XCTAssertTrue(accepted)
        XCTAssertEqual(repostCount, 1)
        _ = view
        await service.close()
    }

    func testResigningFirstResponderDoesNotReleasePointerButton() async throws {
        let keys = try AppleRecordKeys(
            key: Data(repeating: 0x11, count: 16),
            initializationVector: Data(repeating: 0x22, count: 16)
        )
        let transport = DragInputTransport(suspendedSendNumber: 2)
        let session = try makeSession(transport: transport)
        session.install(recordLayer: AppleEncryptedRecordLayer(keys: keys))
        let canvas = AppleCanvas(width: 100, height: 100, tileCount: 1)
        let input = AppleInputController(
            session: session,
            canvas: canvas,
            microseconds: { 123 }
        )
        let view = RemoteVideoCanvasNSView(
            canvas: canvas,
            frames: AppleVideoFrameStore(),
            input: input,
            cursors: nil,
            displayScale: AppleVideoDisplayScale(),
            synchronizesPresentation: true,
            sourceRect: nil,
            inputMapping: nil,
            inputCoordinatesAreDisplayLocal: false,
            inputDisplayID: nil
        )
        view.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        let mouseDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 20, y: 20),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        let move = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: 80, y: 80),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 2,
            clickCount: 0,
            pressure: 0
        ))

        view.mouseDown(with: mouseDown)
        await waitUntil { transport.sentMessages.count == 1 }
        _ = view.resignFirstResponder()
        view.mouseMoved(with: move)
        await transport.waitUntilSendIsSuspended()

        let expectedLayer = AppleEncryptedRecordLayer(keys: keys)
        _ = try expectedLayer.encrypt(try expectedLayer.encryptPointerEvent(
            buttons: AppleInputController.leftButton,
            x: 20,
            y: 80,
            clickCount: 1,
            timestampDelta: 123
        ))
        let expectedMove = try expectedLayer.encryptPointerEvent(
            buttons: AppleInputController.leftButton,
            x: 80,
            y: 20,
            clickCount: 0,
            timestampDelta: 0
        )
        let expectedEncryptedMove = try expectedLayer.encrypt(expectedMove)

        XCTAssertEqual(transport.sentMessages[1], expectedEncryptedMove)
        transport.resumeSuspendedSend()
    }

    func testLocalFileDragStartsAtEntryPointAfterOfferFinishes() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-drag-entry-\(UUID().uuidString).txt")
        try Data("drag".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let harness = try makeLocalFileDragHarness(fileURL: fileURL)

        XCTAssertEqual(harness.view.draggingEntered(harness.dragInfo), .copy)
        await harness.sendGate.waitUntilStarted()
        harness.dragInfo.location = NSPoint(x: 80, y: 70)
        XCTAssertEqual(harness.view.draggingUpdated(harness.dragInfo), .copy)
        await harness.sendGate.resume()
        await waitUntil { harness.transport.sentMessages.count >= 2 }

        let expectedLayer = AppleEncryptedRecordLayer(keys: harness.keys)
        let offer = try AppleFileTransferMessage.beginDrop(
            fileURL: fileURL,
            sessionID: 0x1234
        )
        let expectedOffer = try expectedLayer.encrypt(AppleFileTransferMessage.fragments(of: offer))
        let pointer = try expectedLayer.encryptPointerEvent(
            buttons: AppleInputController.leftButton,
            x: 10,
            y: 80,
            clickCount: 1,
            timestampDelta: 123
        )
        let expectedPointer = try expectedLayer.encrypt(pointer)

        XCTAssertEqual(
            Array(harness.transport.sentMessages.prefix(2)),
            [expectedOffer, expectedPointer]
        )
        await harness.service.close()
    }

    func testLocalFileDragPreservesDownAndUpWhenDropFinishesBeforeOffer() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-drag-fast-drop-\(UUID().uuidString).txt")
        try Data("drag".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let harness = try makeLocalFileDragHarness(fileURL: fileURL)

        XCTAssertEqual(harness.view.draggingEntered(harness.dragInfo), .copy)
        await harness.sendGate.waitUntilStarted()
        harness.dragInfo.location = NSPoint(x: 80, y: 70)
        XCTAssertTrue(harness.view.performDragOperation(harness.dragInfo))
        harness.view.draggingEnded(harness.dragInfo)
        await harness.sendGate.resume()
        await waitUntil { harness.transport.sentMessages.count >= 3 }

        let expectedLayer = AppleEncryptedRecordLayer(keys: harness.keys)
        let offer = try AppleFileTransferMessage.beginDrop(
            fileURL: fileURL,
            sessionID: 0x1234
        )
        let expectedOffer = try expectedLayer.encrypt(AppleFileTransferMessage.fragments(of: offer))
        let down = try expectedLayer.encryptPointerEvent(
            buttons: AppleInputController.leftButton,
            x: 10,
            y: 80,
            clickCount: 1,
            timestampDelta: 123
        )
        let expectedDown = try expectedLayer.encrypt(down)
        let up = try expectedLayer.encryptPointerEvent(
            buttons: 0,
            x: 80,
            y: 30,
            clickCount: 1,
            timestampDelta: 0
        )
        let expectedUp = try expectedLayer.encrypt(up)

        XCTAssertEqual(
            Array(harness.transport.sentMessages.prefix(3)),
            [expectedOffer, expectedDown, expectedUp]
        )
        await harness.service.close()
    }

    func testLocalFileDragKeepsOneRemoteDragAcrossExitAndReentry() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-drag-reentry-\(UUID().uuidString).txt")
        try Data("drag".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let harness = try makeLocalFileDragHarness(fileURL: fileURL)

        XCTAssertEqual(harness.view.draggingEntered(harness.dragInfo), .copy)
        await harness.sendGate.waitUntilStarted()
        await harness.sendGate.resume()
        await waitUntil { harness.transport.sentMessages.count >= 2 }
        harness.view.draggingExited(harness.dragInfo)
        harness.dragInfo.location = NSPoint(x: 80, y: 70)
        XCTAssertEqual(harness.view.draggingEntered(harness.dragInfo), .copy)
        XCTAssertTrue(harness.view.performDragOperation(harness.dragInfo))
        await waitUntil { harness.transport.sentMessages.count >= 4 }

        let expectedLayer = AppleEncryptedRecordLayer(keys: harness.keys)
        let offer = try AppleFileTransferMessage.beginDrop(
            fileURL: fileURL,
            sessionID: 0x1234
        )
        let expectedOffer = try expectedLayer.encrypt(AppleFileTransferMessage.fragments(of: offer))
        let initialDown = try expectedLayer.encryptPointerEvent(
            buttons: AppleInputController.leftButton,
            x: 10,
            y: 80,
            clickCount: 1,
            timestampDelta: 123
        )
        let expectedInitialDown = try expectedLayer.encrypt(initialDown)
        let reentryDown = try expectedLayer.encryptPointerEvent(
            buttons: AppleInputController.leftButton,
            x: 80,
            y: 30,
            clickCount: 1,
            timestampDelta: 0
        )
        let expectedReentryDown = try expectedLayer.encrypt(reentryDown)
        let up = try expectedLayer.encryptPointerEvent(
            buttons: 0,
            x: 80,
            y: 30,
            clickCount: 1,
            timestampDelta: 0
        )
        let expectedUp = try expectedLayer.encrypt(up)

        XCTAssertEqual(
            Array(harness.transport.sentMessages.prefix(4)),
            [expectedOffer, expectedInitialDown, expectedReentryDown, expectedUp]
        )
        await harness.service.close()
    }

    func testLocalFileDragCollapsesBackloggedMovesToLatestPointBeforeMouseUp() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-drag-collation-\(UUID().uuidString).txt")
        try Data("drag".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let harness = try makeLocalFileDragHarness(
            fileURL: fileURL,
            suspendedTransportSendNumber: 2
        )

        XCTAssertEqual(harness.view.draggingEntered(harness.dragInfo), .copy)
        await harness.sendGate.waitUntilStarted()
        await harness.sendGate.resume()
        await harness.transport.waitUntilSendIsSuspended()
        for coordinate in [20, 30, 40, 80] {
            harness.dragInfo.location = NSPoint(x: coordinate, y: coordinate - 10)
            XCTAssertEqual(harness.view.draggingUpdated(harness.dragInfo), .copy)
        }
        XCTAssertTrue(harness.view.performDragOperation(harness.dragInfo))
        harness.transport.resumeSuspendedSend()
        await waitUntil { harness.transport.sentMessages.count >= 4 }

        let expectedLayer = AppleEncryptedRecordLayer(keys: harness.keys)
        let offer = try AppleFileTransferMessage.beginDrop(
            fileURL: fileURL,
            sessionID: 0x1234
        )
        let expectedOffer = try expectedLayer.encrypt(AppleFileTransferMessage.fragments(of: offer))
        let initialDown = try expectedLayer.encryptPointerEvent(
            buttons: AppleInputController.leftButton,
            x: 10,
            y: 80,
            clickCount: 1,
            timestampDelta: 123
        )
        let expectedInitialDown = try expectedLayer.encrypt(initialDown)
        let latestDown = try expectedLayer.encryptPointerEvent(
            buttons: AppleInputController.leftButton,
            x: 80,
            y: 30,
            clickCount: 1,
            timestampDelta: 0
        )
        let expectedLatestDown = try expectedLayer.encrypt(latestDown)
        let up = try expectedLayer.encryptPointerEvent(
            buttons: 0,
            x: 80,
            y: 30,
            clickCount: 1,
            timestampDelta: 0
        )
        let expectedUp = try expectedLayer.encrypt(up)

        XCTAssertEqual(
            Array(harness.transport.sentMessages.prefix(4)),
            [expectedOffer, expectedInitialDown, expectedLatestDown, expectedUp]
        )
        await harness.service.close()
    }

    private func makeLocalFileDragHarness(
        fileURL: URL,
        suspendedTransportSendNumber: Int? = nil
    ) throws -> LocalFileDragHarness {
        let keys = try AppleRecordKeys(
            key: Data(repeating: 0x11, count: 16),
            initializationVector: Data(repeating: 0x22, count: 16)
        )
        let transport = DragInputTransport(
            suspendedSendNumber: suspendedTransportSendNumber
        )
        let session = try makeSession(transport: transport)
        session.install(recordLayer: AppleEncryptedRecordLayer(keys: keys))
        let canvas = AppleCanvas(width: 100, height: 100, tileCount: 1)
        let input = AppleInputController(
            session: session,
            canvas: canvas,
            microseconds: { 123 }
        )
        let sendGate = ControlledFileTransferSend(session: session)
        let service = AppleFileTransferService(
            remoteName: "Remote Mac",
            history: AppleFileTransferHistory(),
            makeSessionID: { 0x1234 },
            send: { messages in try await sendGate.send(messages) }
        )
        let view = RemoteVideoCanvasNSView(
            canvas: canvas,
            frames: AppleVideoFrameStore(),
            input: input,
            fileTransfer: service,
            cursors: nil,
            displayScale: AppleVideoDisplayScale(),
            synchronizesPresentation: true,
            sourceRect: nil,
            inputMapping: nil,
            inputCoordinatesAreDisplayLocal: false,
            inputDisplayID: nil
        )
        view.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        let pasteboard = NSPasteboard(name: .init("remote-drag-\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([fileURL as NSURL]))
        let dragInfo = TestDraggingInfo(
            location: NSPoint(x: 10, y: 20),
            pasteboard: pasteboard
        )
        return LocalFileDragHarness(
            keys: keys,
            transport: transport,
            session: session,
            service: service,
            sendGate: sendGate,
            view: view,
            dragInfo: dragInfo
        )
    }

    private func makeSession() throws -> RFBAuthenticatedSession {
        try makeSession(transport: NWConnectionTransport(
            remoteAddress: ResolvedRemoteAddress(numericHost: "127.0.0.1", port: 5900)
        ))
    }

    private func makeSession(transport: any RFBTransport) throws -> RFBAuthenticatedSession {
        let endpoint = try ConnectionEndpoint(host: "127.0.0.1")
        let remoteAddress = try ResolvedRemoteAddress(
            numericHost: endpoint.host,
            port: endpoint.port
        )
        return RFBAuthenticatedSession(
            endpoint: endpoint,
            remoteAddress: remoteAddress,
            masterKey: Data(repeating: 0, count: 16),
            serverInfo: RFBServerInfo(
                width: 1_920,
                height: 1_080,
                pixelFormat: Data(repeating: 0, count: 16),
                name: "Test Mac"
            ),
            transport: transport
        )
    }

    private func waitUntil(_ predicate: @escaping () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if predicate() { return }
            try? await clock.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for remote drag input")
    }
}

@MainActor
private struct LocalFileDragHarness {
    let keys: AppleRecordKeys
    let transport: DragInputTransport
    let session: RFBAuthenticatedSession
    let service: AppleFileTransferService
    let sendGate: ControlledFileTransferSend
    let view: RemoteVideoCanvasNSView
    let dragInfo: TestDraggingInfo
}

@MainActor
private final class TestDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    var location: NSPoint
    let pasteboard: NSPasteboard

    init(location: NSPoint, pasteboard: NSPasteboard) {
        self.location = location
        self.pasteboard = pasteboard
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) { }

    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? {
        nil
    }

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) { }

    func resetSpringLoading() { }
}

private final class DragInputTransport: RFBTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let suspendedSendNumber: Int?
    private var messages = [Data]()
    private var suspensionWasReleased = false
    private var suspendedSend: CheckedContinuation<Void, Never>?
    private var suspensionWaiters = [CheckedContinuation<Void, Never>]()

    init(suspendedSendNumber: Int? = nil) {
        self.suspendedSendNumber = suspendedSendNumber
    }

    var sentMessages: [Data] {
        lock.withLock { messages }
    }

    func start(timeout: Duration) async throws { }

    func send(_ data: Data) async throws {
        let shouldSuspend = lock.withLock {
            messages.append(data)
            return messages.count == suspendedSendNumber && !suspensionWasReleased
        }
        guard shouldSuspend else { return }
        await withCheckedContinuation { continuation in
            let state = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
                if suspensionWasReleased { return (true, []) }
                suspendedSend = continuation
                let waiters = suspensionWaiters
                suspensionWaiters.removeAll()
                return (false, waiters)
            }
            state.1.forEach { $0.resume() }
            if state.0 { continuation.resume() }
        }
    }

    func waitUntilSendIsSuspended() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if suspendedSend != nil { return true }
                suspensionWaiters.append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func resumeSuspendedSend() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            suspensionWasReleased = true
            defer { suspendedSend = nil }
            return suspendedSend
        }
        continuation?.resume()
    }

    func receiveExactly(_ length: Int) async throws -> Data {
        throw RFBNetworkError.connectionClosed
    }

    func cancel() { }
}

private actor ControlledFileTransferSend {
    private weak var session: RFBAuthenticatedSession?
    private var continuation: CheckedContinuation<Void, Never>?
    private var startWaiters = [CheckedContinuation<Void, Never>]()
    private var shouldSuspend = true

    init(session: RFBAuthenticatedSession) {
        self.session = session
    }

    func send(_ messages: [Data]) async throws {
        if shouldSuspend {
            shouldSuspend = false
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        guard let session else { throw CancellationError() }
        try await session.sendEncrypted(messages)
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
