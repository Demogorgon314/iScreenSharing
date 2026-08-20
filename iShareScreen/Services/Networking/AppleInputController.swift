import Foundation

actor AppleInputController {
    static let leftButton: UInt8 = 1 << 0
    static let rightButton: UInt8 = 1 << 1
    static let middleButton: UInt8 = 1 << 2
    static let scrollUp: UInt8 = 1 << 3
    static let scrollDown: UInt8 = 1 << 4

    private weak var session: RFBAuthenticatedSession?
    private var canvas: AppleCanvas
    private var isClosed = false
    private(set) var sentEventCount = 0

    init(session: RFBAuthenticatedSession, canvas: AppleCanvas) {
        self.session = session
        self.canvas = canvas
    }

    func pointer(buttons: UInt8, x: Int, y: Int) async {
        guard let session, let recordLayer = session.recordLayer, !isClosed else { return }
        let point = Self.clampedPoint(x: x, y: y, canvas: canvas)
        do {
            let message = try AppleRFBMessages.encryptedPointerEvent(
                buttons: buttons,
                x: point.x,
                y: point.y,
                contentKey: recordLayer.contentKey
            )
            try await session.sendEncrypted(message)
            sentEventCount += 1
        } catch {
            // Input is best effort. Session-level failures surface through the active connection.
        }
    }

    func scroll(up: Bool, ticks: Int, x: Int, y: Int) async {
        let count = min(max(ticks, 0), 50)
        guard count > 0 else { return }
        for _ in 0..<count {
            await pointer(buttons: up ? Self.scrollUp : Self.scrollDown, x: x, y: y)
            await pointer(buttons: 0, x: x, y: y)
        }
    }

    func key(isDown: Bool, symbol: UInt32) async {
        guard symbol != 0, let session, !isClosed else { return }
        do {
            try await session.sendEncrypted(AppleRFBMessages.keyEvent(isDown: isDown, keySymbol: symbol))
            sentEventCount += 1
        } catch {
            // A stale input event must not disrupt AppKit's event loop during disconnect.
        }
    }

    func enableClipboard() async {
        await send(AppleClipboardMessage.enable)
    }

    func fetchClipboard() async {
        await send(AppleClipboardMessage.fetch)
    }

    func sendClipboard(_ text: String) async throws {
        let message = try AppleClipboardMessage.send(text: text)
        for fragment in AppleClipboardMessage.fragments(of: message) {
            try await sendThrowing(fragment)
        }
    }

    func close() {
        isClosed = true
    }

    func update(canvas: AppleCanvas) {
        self.canvas = canvas
    }

    private func send(_ message: Data) async {
        try? await sendThrowing(message)
    }

    private func sendThrowing(_ message: Data) async throws {
        guard let session, !isClosed else { return }
        try await session.sendEncrypted(message)
        sentEventCount += 1
    }

    static func clampedPoint(x: Int, y: Int, canvas: AppleCanvas) -> (x: UInt16, y: UInt16) {
        let maximumX = max(0, min(canvas.width - 1, Int(UInt16.max)))
        let maximumY = max(0, min(canvas.height - 1, Int(UInt16.max)))
        return (
            UInt16(min(max(x, 0), maximumX)),
            UInt16(min(max(y, 0), maximumY))
        )
    }
}
