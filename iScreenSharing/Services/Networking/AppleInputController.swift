import Carbon
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
    private var keyboardEventSubtype: UInt8 = 1
    private var isControlling = true
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
        _ = await sendPointer(
            buttons: buttons,
            x: x,
            y: y,
            displayID: displayID,
            clickCount: clickCount
        )
    }

    func fileDragPointer(
        buttons: UInt8,
        x: Int,
        y: Int,
        displayID: UInt32? = nil
    ) async {
        // Native HP drag events retain a click count of one through down and up;
        // Finder drop targets do not accept the otherwise equivalent zero-count sequence.
        _ = await sendPointer(
            buttons: buttons,
            x: x,
            y: y,
            displayID: displayID,
            clickCount: 1
        )
    }

    private func sendPointer(
        buttons: UInt8,
        x: Int,
        y: Int,
        displayID: UInt32?,
        clickCount: Int
    ) async -> Bool {
        guard isControlling, let session, !isClosed else {
            return false
        }
        let point = Self.clampedPoint(
            x: x,
            y: y,
            canvas: displayID == nil ? canvas : nil
        )
        do {
            if session.sharingType == .standard {
                try await session.sendStandard(StandardRFBMessages.pointerEvent(
                    buttons: buttons,
                    x: point.x,
                    y: point.y
                ))
                sentEventCount += 1
                return true
            }
            guard let recordLayer = session.recordLayer else { return false }
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
            return true
        } catch {
            displaySelection = AppleInputDisplaySelection()
            // Input is best effort. Session-level failures surface through the active connection.
            return false
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
        guard isControlling, let session, !isClosed else { return }
        if session.sharingType == .standard {
            await scroll(
                verticalTicks: Int(event.deltaY),
                horizontalTicks: Int(event.deltaX),
                x: x,
                y: y,
                displayID: displayID
            )
            return
        }
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
        guard isControlling, let session, !isClosed,
              session.sharingType == .highPerformance,
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
        guard isControlling, symbol != 0,
              let session, !isClosed else { return }
        do {
            if session.sharingType == .standard {
                try await session.sendStandard(StandardRFBMessages.keyEvent(
                    isDown: isDown,
                    symbol: symbol
                ))
                sentEventCount += 1
                return
            }
            guard let recordLayer = session.recordLayer else { return }
            let message = try AppleRFBMessages.encryptedKeyEvent(
                isDown: isDown,
                keySymbol: symbol,
                timestampDelta: inputTimestamp.next(at: microseconds()),
                keyboardType: keyboardType,
                keyCode: keyCode,
                subtype: keyboardEventSubtype,
                contentKey: recordLayer.contentKey
            )
            try await session.sendEncrypted(message)
            sentEventCount += 1
        } catch {
            // A stale input event must not disrupt AppKit's event loop during disconnect.
        }
    }

    func perform(_ command: AppleRemoteSystemCommand) async {
        guard isControlling else { return }
        await key(
            isDown: true,
            symbol: command.rawValue,
            keyCode: UInt16(truncatingIfNeeded: command.rawValue),
            keyboardType: UInt16(LMGetKbdType())
        )
    }

    func setUsesSameInputSource(_ usesSameInputSource: Bool) {
        keyboardEventSubtype = usesSameInputSource ? 3 : 1
    }

    func setControlling(_ controlling: Bool) {
        isControlling = controlling
    }

    func enableClipboard() async {
        guard isControlling else { return }
        await send(AppleClipboardMessage.enable)
    }

    func requestClipboard(promises: Bool, sessionID: UInt32) async throws {
        guard isControlling else { throw AppleInputControllerError.notControlling }
        try await sendThrowing(
            AppleClipboardMessage.request(promises: promises, sessionID: sessionID)
        )
    }

    func sendClipboard(
        _ archive: AppleClipboardArchive,
        promises: Bool = false,
        sessionID: UInt32 = 0
    ) async throws {
        guard isControlling else { throw AppleInputControllerError.notControlling }
        let message = try AppleClipboardMessage.send(
            archive: archive,
            promises: promises,
            sessionID: sessionID
        )
        for fragment in AppleClipboardMessage.fragments(of: message) {
            try await sendThrowing(fragment)
        }
    }

    func sendClipboard(_ text: String) async throws {
        try await sendClipboard(.text(text))
    }

    func disableClipboard() async {
        await send(AppleClipboardMessage.disable)
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
        if session.sharingType == .standard {
            throw AppleInputControllerError.unsupportedInStandardMode
        }
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

enum AppleInputControllerError: LocalizedError, Equatable {
    case notControlling
    case unsupportedInStandardMode

    var errorDescription: String? {
        switch self {
        case .notControlling:
            "Remote input is unavailable while observing the shared Mac."
        case .unsupportedInStandardMode:
            "This clipboard command is unavailable in Standard Screen Sharing."
        }
    }
}
