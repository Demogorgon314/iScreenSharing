import Foundation
import enum ScreenSharingProtocol.AppleCursorUpdate
import enum ScreenSharingProtocol.AppleFramebufferUpdate
import enum ScreenSharingProtocol.AppleMediaConfiguration
import struct ScreenSharingProtocol.AppleCanvas
import struct ScreenSharingProtocol.AppleDisplayLayout
import struct ScreenSharingProtocol.AppleRemoteDeviceInfo

final class AppleControlMessageService: @unchecked Sendable {
    private weak var session: RFBAuthenticatedSession?
    private let clipboardExchange: AppleClipboardExchange
    private let pendingMessages: [Data]
    private let receiveDisplayLayout: @Sendable (AppleDisplayLayout) async -> Void
    private let receiveMediaCanvas: @Sendable (AppleCanvas) async -> Void
    private let receiveCursorUpdate: @Sendable (AppleCursorUpdate) async -> Void
    private let receiveVendorKeySymbols: @Sendable (Set<UInt32>) async -> Void
    private let receiveKeyboardInputSource: @Sendable (AppleKeyboardInputSourceState) async -> Void
    private let receiveDeviceInfo: @Sendable (AppleRemoteDeviceInfo) async -> Void
    private let receiveFileTransferMessage: @Sendable (Data) async -> Bool
    private let countLock = NSLock()
    private var task: Task<Void, Never>?
    private var messageCount = 0

    init(
        session: RFBAuthenticatedSession,
        input: AppleInputController,
        clipboard: any AppleClipboardReceiving,
        pendingMessages: [Data],
        receiveDisplayLayout: @escaping @Sendable (AppleDisplayLayout) async -> Void = { _ in },
        receiveMediaCanvas: @escaping @Sendable (AppleCanvas) async -> Void = { _ in },
        receiveCursorUpdate: @escaping @Sendable (AppleCursorUpdate) async -> Void = { _ in },
        receiveVendorKeySymbols: @escaping @Sendable (Set<UInt32>) async -> Void = { _ in },
        receiveKeyboardInputSource: @escaping @Sendable (AppleKeyboardInputSourceState) async -> Void = { _ in },
        receiveDeviceInfo: @escaping @Sendable (AppleRemoteDeviceInfo) async -> Void = { _ in },
        receiveFileTransferMessage: @escaping @Sendable (Data) async -> Bool = { _ in false }
    ) {
        self.session = session
        clipboardExchange = AppleClipboardExchange(
            clipboard: clipboard,
            sendRequest: { promises, sessionID in
                try await input.requestClipboard(promises: promises, sessionID: sessionID)
            },
            sendArchive: { archive, promises, sessionID in
                try await input.sendClipboard(
                    archive,
                    promises: promises,
                    sessionID: sessionID
                )
            }
        )
        self.pendingMessages = pendingMessages
        self.receiveDisplayLayout = receiveDisplayLayout
        self.receiveMediaCanvas = receiveMediaCanvas
        self.receiveCursorUpdate = receiveCursorUpdate
        self.receiveVendorKeySymbols = receiveVendorKeySymbols
        self.receiveKeyboardInputSource = receiveKeyboardInputSource
        self.receiveDeviceInfo = receiveDeviceInfo
        self.receiveFileTransferMessage = receiveFileTransferMessage
    }

    var receivedMessageCount: Int {
        countLock.withControlMessageLock { messageCount }
    }

    func requestRemoteClipboard() async throws {
        try await clipboardExchange.requestRemoteClipboard()
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func close() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }

    private func run() async {
        for message in pendingMessages {
            await process(message)
        }

        while !Task.isCancelled, let session {
            do {
                let message = try await session.receiveEncrypted()
                await process(message)
            } catch {
                return
            }
        }
    }

    private func process(_ message: Data) async {
        guard !message.isEmpty else { return }
        countLock.withControlMessageLock { messageCount += 1 }
        if await receiveFileTransferMessage(message) { return }
        if message[0] == 0 {
            if let canvas = AppleMediaConfiguration.canvas(from: message) {
                await receiveMediaCanvas(canvas)
            }
            let contents = AppleFramebufferUpdate.contents(from: message)
            for layout in contents.displayLayouts {
                await receiveDisplayLayout(layout)
            }
            for update in contents.cursorUpdates {
                await receiveCursorUpdate(update)
            }
            for symbols in contents.vendorKeySymbols {
                await receiveVendorKeySymbols(symbols)
            }
            for state in contents.keyboardInputSources {
                await receiveKeyboardInputSource(state)
            }
            for info in contents.deviceInfos {
                await receiveDeviceInfo(info)
            }
            return
        }
        _ = await clipboardExchange.receive(message)
    }
}

private extension NSLock {
    func withControlMessageLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
