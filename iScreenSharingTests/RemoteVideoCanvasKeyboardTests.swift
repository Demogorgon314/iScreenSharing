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

    private func makeSession() throws -> RFBAuthenticatedSession {
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
            transport: NWConnectionTransport(remoteAddress: remoteAddress)
        )
    }
}
