import Foundation

final class AppleControlMessageService: @unchecked Sendable {
    private weak var session: RFBAuthenticatedSession?
    private let input: AppleInputController
    private let clipboard: any AppleClipboardReceiving
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
        self.input = input
        self.clipboard = clipboard
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
        var reassembler = AppleClipboardReassembler()
        var clipboardRequest = ClipboardRequestState.idle
        await input.enableClipboard()
        for message in pendingMessages {
            await process(
                message,
                reassembler: &reassembler,
                clipboardRequest: &clipboardRequest
            )
        }

        while !Task.isCancelled, let session {
            do {
                let message = try await session.receiveEncrypted()
                await process(
                    message,
                    reassembler: &reassembler,
                    clipboardRequest: &clipboardRequest
                )
            } catch {
                return
            }
        }
    }

    private func process(
        _ message: Data,
        reassembler: inout AppleClipboardReassembler,
        clipboardRequest: inout ClipboardRequestState
    ) async {
        guard !message.isEmpty else { return }
        if let lease = clipboardRequest.lease,
           !(await clipboard.isSynchronizationLeaseValid(lease)) {
            clipboardRequest = .idle
            reassembler = AppleClipboardReassembler()
        }
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
        if reassembler.isInProgress || message[0] == 0x1f {
            do {
                if let complete = try reassembler.process(message) {
                    let envelope = try AppleClipboardMessage.envelope(from: complete)
                    switch clipboardRequest {
                    case .awaitingPromises(let sessionID, let lease)
                        where envelope.sessionID == sessionID && envelope.containsPromises:
                        guard await clipboard.isSynchronizationLeaseValid(lease) else {
                            clipboardRequest = .idle
                            return
                        }
                        do {
                            let fullSessionID = try await input.requestClipboard(promises: false)
                            guard await clipboard.isSynchronizationLeaseValid(lease) else {
                                clipboardRequest = .idle
                                return
                            }
                            clipboardRequest = .awaitingFull(id: fullSessionID, lease: lease)
                        } catch {
                            clipboardRequest = .idle
                        }
                    case .awaitingFull(let sessionID, let lease)
                        where envelope.sessionID == sessionID && !envelope.containsPromises:
                        _ = await clipboard.receiveIfEligible(envelope.archive, lease: lease)
                        clipboardRequest = .idle
                    default:
                        return
                    }
                }
            } catch {
                reassembler = AppleClipboardReassembler()
            }
            return
        }
        if let request = AppleClipboardMessage.request(from: message),
           let archive = await clipboard.archiveForRemoteRequest() {
            try? await input.sendClipboard(
                archive,
                promises: request.requestsPromises,
                sessionID: request.sessionID
            )
            return
        }
        if message[0] == 0x14,
           message.count >= 8,
           (try? message.uint16BE(at: 6)) == 2,
           case .idle = clipboardRequest,
           let lease = await clipboard.synchronizationLease() {
            do {
                let sessionID = try await input.requestClipboard(promises: true)
                guard await clipboard.isSynchronizationLeaseValid(lease) else { return }
                clipboardRequest = .awaitingPromises(id: sessionID, lease: lease)
            } catch {
                clipboardRequest = .idle
            }
        }
    }
}

private enum ClipboardRequestState {
    case idle
    case awaitingPromises(id: UInt32, lease: UInt64)
    case awaitingFull(id: UInt32, lease: UInt64)

    var lease: UInt64? {
        switch self {
        case .idle: nil
        case .awaitingPromises(_, let lease), .awaitingFull(_, let lease): lease
        }
    }
}

private extension NSLock {
    func withControlMessageLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
