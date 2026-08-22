import Foundation

struct AppleInputDisplaySelection {
    private var selectedDisplayID: UInt32?

    mutating func message(for displayID: UInt32?) -> Data? {
        guard displayID != selectedDisplayID else { return nil }
        selectedDisplayID = displayID
        return displayID.map(AppleRFBMessages.selectDisplay) ?? AppleRFBMessages.selectCombinedDisplays
    }
}

struct AppleInputTimestamp {
    private var previous: UInt32 = 0

    mutating func next(at microseconds: UInt64) -> UInt32 {
        let current = UInt32(truncatingIfNeeded: microseconds)
        defer { previous = current }
        return current &- previous
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
    private var inputTimestamp = AppleInputTimestamp()
    private let microseconds: @Sendable () -> UInt64
    private var isClosed = false
    private(set) var sentEventCount = 0

    init(
        session: RFBAuthenticatedSession,
        canvas: AppleCanvas,
        microseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds / 1_000
        }
    ) {
        self.session = session
        self.canvas = canvas
        self.microseconds = microseconds
    }

    func pointer(
        buttons: UInt8,
        x: Int,
        y: Int,
        displayID: UInt32? = nil,
        clickCount: Int = 0
    ) async {
        guard let session, let recordLayer = session.recordLayer, !isClosed else { return }
        let point = Self.clampedPoint(
            x: x,
            y: y,
            canvas: displayID == nil ? canvas : nil
        )
        do {
            var messages = [Data]()
            if let selectionMessage = displaySelection.message(for: displayID) {
                messages.append(selectionMessage)
            }
            let message = try AppleRFBMessages.encryptedPointerEvent(
                buttons: buttons,
                x: point.x,
                y: point.y,
                clickCount: clickCount,
                timestampDelta: inputTimestamp.next(at: microseconds()),
                contentKey: recordLayer.contentKey
            )
            messages.append(message)
            try await session.sendEncrypted(messages)
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

    func scroll(
        event: AppleScrollWheelEvent,
        x: Int,
        y: Int,
        displayID: UInt32? = nil
    ) async {
        guard let session, !isClosed else { return }
        let point = Self.clampedPoint(
            x: x,
            y: y,
            canvas: displayID == nil ? canvas : nil
        )
        var messages = [Data]()
        if let selectionMessage = displaySelection.message(for: displayID) {
            messages.append(selectionMessage)
        }
        messages.append(AppleRFBMessages.scrollWheelEvent(event, x: point.x, y: point.y))
        do {
            try await session.sendEncrypted(messages)
            sentEventCount += 1
        } catch {
            displaySelection = AppleInputDisplaySelection()
            // Input is best effort. Session-level failures surface through the active connection.
        }
    }

    static func scrollButtons(verticalTicks: Int, horizontalTicks: Int) -> [UInt8] {
        let axes: [(ticks: Int, positive: UInt8, negative: UInt8)] = [
            (verticalTicks, scrollUp, scrollDown),
            (horizontalTicks, scrollLeft, scrollRight),
        ]
        return axes.flatMap { ticks, positiveButton, negativeButton -> [UInt8] in
            guard ticks != 0 else { return [] }
            let button = ticks > 0 ? positiveButton : negativeButton
            return [button, 0]
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

    func key(
        isDown: Bool,
        symbol: UInt32,
        keyCode: UInt16 = 0,
        keyboardType: UInt16 = 0
    ) async {
        guard symbol != 0, let session, let recordLayer = session.recordLayer, !isClosed else { return }
        do {
            let message = try AppleRFBMessages.encryptedKeyEvent(
                isDown: isDown,
                keySymbol: symbol,
                timestampDelta: inputTimestamp.next(at: microseconds()),
                keyboardType: keyboardType,
                keyCode: keyCode,
                contentKey: recordLayer.contentKey
            )
            try await session.sendEncrypted(message)
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

    static func clampedPoint(x: Int, y: Int, canvas: AppleCanvas?) -> (x: UInt16, y: UInt16) {
        let maximumX = canvas.map { max(0, min($0.width - 1, Int(UInt16.max))) }
            ?? Int(UInt16.max)
        let maximumY = canvas.map { max(0, min($0.height - 1, Int(UInt16.max))) }
            ?? Int(UInt16.max)
        return (
            UInt16(min(max(x, 0), maximumX)),
            UInt16(min(max(y, 0), maximumY))
        )
    }
}
