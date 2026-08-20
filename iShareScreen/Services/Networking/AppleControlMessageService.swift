import Foundation

final class AppleControlMessageService: @unchecked Sendable {
    private weak var session: RFBAuthenticatedSession?
    private let input: AppleInputController
    private let clipboard: any AppleClipboardReceiving
    private let pendingMessages: [Data]
    private let receiveDisplayLayout: @Sendable (AppleDisplayLayout) async -> Void
    private let countLock = NSLock()
    private var task: Task<Void, Never>?
    private var messageCount = 0

    init(
        session: RFBAuthenticatedSession,
        input: AppleInputController,
        clipboard: any AppleClipboardReceiving,
        pendingMessages: [Data],
        receiveDisplayLayout: @escaping @Sendable (AppleDisplayLayout) async -> Void = { _ in }
    ) {
        self.session = session
        self.input = input
        self.clipboard = clipboard
        self.pendingMessages = pendingMessages
        self.receiveDisplayLayout = receiveDisplayLayout
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
        for message in pendingMessages {
            await process(message, reassembler: &reassembler)
        }
        await input.enableClipboard()
        await input.fetchClipboard()

        while !Task.isCancelled, let session {
            do {
                let message = try await session.receiveEncrypted()
                await process(message, reassembler: &reassembler)
            } catch {
                return
            }
        }
    }

    private func process(
        _ message: Data,
        reassembler: inout AppleClipboardReassembler
    ) async {
        guard !message.isEmpty else { return }
        countLock.withControlMessageLock { messageCount += 1 }
        if message[0] == 0 {
            for layout in AppleFramebufferUpdate.displayLayouts(from: message) {
                await receiveDisplayLayout(layout)
            }
            return
        }
        if reassembler.isInProgress || message[0] == 0x1f {
            do {
                if let complete = try reassembler.process(message),
                   let text = try AppleClipboardMessage.text(from: complete) {
                    await clipboard.receive(text)
                }
            } catch {
                reassembler = AppleClipboardReassembler()
            }
            return
        }
        if message[0] == 0x14,
           message.count >= 8,
           (try? message.uint16BE(at: 6)) == 2 {
            await input.fetchClipboard()
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
