import Foundation

struct AppleInputDisplaySelection {
    private var selectedDisplayID: UInt32?

    mutating func message(for displayID: UInt32?) -> Data? {
        guard displayID != selectedDisplayID else { return nil }
        selectedDisplayID = displayID
        return displayID.map(AppleRFBMessages.selectDisplay) ?? AppleRFBMessages.selectCombinedDisplays
    }
}

actor AppleInputController {
    static let leftButton: UInt8 = 1 << 0
    static let rightButton: UInt8 = 1 << 1
    static let middleButton: UInt8 = 1 << 2
    static let scrollUp: UInt8 = 1 << 3
    static let scrollDown: UInt8 = 1 << 4
    static let scrollLeft: UInt8 = 1 << 5
    static let scrollRight: UInt8 = 1 << 6

    private weak var session: RFBAuthenticatedSession?
    private var canvas: AppleCanvas
    private var displaySelection = AppleInputDisplaySelection()
    private var isClosed = false
    private(set) var sentEventCount = 0

    init(session: RFBAuthenticatedSession, canvas: AppleCanvas) {
        self.session = session
        self.canvas = canvas
    }

    func pointer(
        buttons: UInt8,
        x: Int,
        y: Int,
        displayID: UInt32? = nil,
        clickCount: Int = 0
    ) async {
        guard let session, let recordLayer = session.recordLayer, !isClosed else { return }
        let point = Self.clampedPoint(x: x, y: y, canvas: canvas)
        do {
            if let selectionMessage = displaySelection.message(for: displayID) {
                try await session.sendEncrypted(selectionMessage)
            }
            let message = try AppleRFBMessages.encryptedPointerEvent(
                buttons: buttons,
                x: point.x,
                y: point.y,
                clickCount: clickCount,
                contentKey: recordLayer.contentKey
            )
            try await session.sendEncrypted(message)
            sentEventCount += 1
        } catch {
            displaySelection = AppleInputDisplaySelection()
            // Input is best effort. Session-level failures surface through the active connection.
        }
    }

    func scroll(up: Bool, ticks: Int, x: Int, y: Int, displayID: UInt32? = nil) async {
        await scroll(
            verticalTicks: up ? ticks : -ticks,
            horizontalTicks: 0,
            x: x,
            y: y,
            displayID: displayID
        )
    }

    func scroll(
        verticalTicks: Int,
        horizontalTicks: Int,
        x: Int,
        y: Int,
        displayID: UInt32? = nil
    ) async {
        for button in Self.scrollButtons(
            verticalTicks: verticalTicks,
            horizontalTicks: horizontalTicks
        ) {
            await pointer(buttons: button, x: x, y: y, displayID: displayID)
        }
    }

    static func scrollButtons(verticalTicks: Int, horizontalTicks: Int) -> [UInt8] {
        let axes: [(ticks: Int, positive: UInt8, negative: UInt8)] = [
            (verticalTicks, scrollUp, scrollDown),
            (horizontalTicks, scrollLeft, scrollRight),
        ]
        return axes.flatMap { ticks, positiveButton, negativeButton -> [UInt8] in
            let count = min(abs(ticks), 50)
            guard count > 0 else { return [] }
            let button = ticks > 0 ? positiveButton : negativeButton
            return Array(repeating: [button, 0], count: count).flatMap { $0 }
        }
    }

    func selectDisplay(_ displayID: UInt32?) async {
        guard let session, !isClosed,
              let message = displaySelection.message(for: displayID) else { return }
        do {
            try await session.sendEncrypted(message)
            sentEventCount += 1
        } catch {
            displaySelection = AppleInputDisplaySelection()
            // Focus selection is retried with the next pointer event.
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
