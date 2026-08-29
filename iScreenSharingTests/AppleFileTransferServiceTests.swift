import Foundation
import enum ScreenSharingProtocol.AppleFileCopyToolOutput
import enum ScreenSharingProtocol.AppleFileTransferMessage
import XCTest
@testable import iScreenSharing

@MainActor
final class AppleFileTransferServiceTests: XCTestCase {
    func testHistoryProgressIsMonotonicAndClearKeepsActiveTransfer() {
        let history = AppleFileTransferHistory()
        let activeID = history.begin(
            fileURL: URL(fileURLWithPath: "/tmp/active.bin"),
            remoteName: "Remote Mac"
        )
        XCTAssertTrue(history.preventsNewDrop)
        let completedID = history.begin(
            fileURL: URL(fileURLWithPath: "/tmp/completed.bin"),
            remoteName: "Remote Mac"
        )

        history.update(activeID, progress: 0.75, state: .sending)
        history.update(activeID, progress: 0.25)
        history.update(activeID, progress: .nan)
        history.update(completedID, progress: 1, state: .sent)
        history.clearCompleted()

        XCTAssertEqual(history.entries.map(\.id), [activeID])
        XCTAssertEqual(history.entries.first?.progress, 0.75)
        XCTAssertTrue(history.hasActiveTransfer)
    }

    func testSystemSenderAdapterStreamsNativeFrames() async throws {
        let sender = AppleSystemFileCopySender()
        guard sender.isAvailable else {
            throw XCTSkip("The native Screen Sharing file sender is unavailable.")
        }
        let fileURL = try makeTemporaryFile(contents: Data([0x58]))
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let recorder = FileCopyToolOutputRecorder()

        try await sender.run(for: fileURL, sessionID: 0x1234) { output in
            await recorder.record(output)
        }
        let result = try await recorder.result(sessionID: 0x1234)

        XCTAssertEqual(result.commands, [100, 101, 102, 104])
        XCTAssertEqual(result.itemInfoTotalBytes, 1)
        XCTAssertEqual(result.finishedStatus, 0)
    }

    func testDoesNotReportSuccessUntilMatchingRemoteCompletionArrives() async throws {
        let fileURL = try makeTemporaryFile(contents: Data([0x58]))
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let sender = FakeFileCopySender(outputs: nativeSenderOutputs())
        let recorder = FileTransferSendRecorder()
        let history = AppleFileTransferHistory()
        let service = AppleFileTransferService(
            remoteName: "Remote Mac",
            history: history,
            sender: sender,
            makeSessionID: { 0x1234 },
            send: { messages in await recorder.record(messages) }
        )

        let sessionID = try await service.beginDrop(fileURL: fileURL)
        XCTAssertEqual(sessionID, 0x1234)
        let receivedRequest = await service.receive(type30Request())
        XCTAssertTrue(receivedRequest)
        await waitUntil { history.entries.first?.state == .completing }

        XCTAssertEqual(history.entries.first?.progress, 1)
        XCTAssertEqual(history.entries.first?.state, .completing)
        let receivedCompletion = await service.receive(completionResponse(errorCode: 0))
        XCTAssertTrue(receivedCompletion)
        await waitUntil { history.entries.first?.state == .sent }
        XCTAssertEqual(history.entries.first?.state, .sent)

        let messages = await recorder.messages
        XCTAssertEqual(messages.first?.first, 0x20)
        XCTAssertTrue(messages.contains { $0.count >= 10 && $0.first == 0x22 })
    }

    func testPendingDropDoesNotAppearInHistoryUntilRemoteAcceptsIt() async throws {
        let fileURL = try makeTemporaryFile(contents: Data([0x58]))
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let history = AppleFileTransferHistory()
        let service = AppleFileTransferService(
            remoteName: "Remote Mac",
            history: history,
            sender: PausingFileCopySender(),
            makeSessionID: { 0x1234 },
            send: { _ in }
        )

        _ = try await service.beginDrop(fileURL: fileURL)
        XCTAssertTrue(history.entries.isEmpty)

        _ = await service.receive(type30Request())
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries.first?.fileURL, fileURL)
        XCTAssertEqual(history.entries.first?.state, .sending)
        await service.close()
    }

    func testNewDropSupersedesPendingWithoutSendingCancel() async throws {
        let firstURL = try makeTemporaryFile(contents: Data([0x41]))
        let secondURL = try makeTemporaryFile(contents: Data([0x42]))
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        let sessionIDs = LockedSessionIDs([0x1234, 0x5678])
        let recorder = FileTransferSendRecorder()
        let history = AppleFileTransferHistory()
        let service = AppleFileTransferService(
            remoteName: "Remote Mac",
            history: history,
            sender: FakeFileCopySender(outputs: []),
            makeSessionID: { sessionIDs.next() },
            send: { messages in await recorder.record(messages) }
        )

        let firstSessionID = try await service.beginDrop(fileURL: firstURL)
        let secondSessionID = try await service.beginDrop(fileURL: secondURL)

        XCTAssertEqual(firstSessionID, 0x1234)
        XCTAssertEqual(secondSessionID, 0x5678)
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertFalse(history.preventsNewDrop)
        let messages = await recorder.messages
        XCTAssertEqual(messages, [
            try AppleFileTransferMessage.beginDrop(fileURL: firstURL, sessionID: 0x1234),
            try AppleFileTransferMessage.beginDrop(fileURL: secondURL, sessionID: 0x5678),
        ])

        _ = await service.receive(type30Request(sessionID: 0x1234))
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testSupersedingAnInFlightBeginDoesNotReturnItsObsoleteSessionID() async throws {
        let firstURL = try makeTemporaryFile(contents: Data([0x41]))
        let secondURL = try makeTemporaryFile(contents: Data([0x42]))
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        let sessionIDs = LockedSessionIDs([0x1234, 0x5678])
        let recorder = SuspendedFirstSendRecorder()
        let history = AppleFileTransferHistory()
        let service = AppleFileTransferService(
            remoteName: "Remote Mac",
            history: history,
            sender: FakeFileCopySender(outputs: []),
            makeSessionID: { sessionIDs.next() },
            send: { messages in await recorder.record(messages) }
        )

        let firstBegin = Task {
            try await service.beginDrop(fileURL: firstURL)
        }
        await recorder.waitUntilFirstSendStarts()
        let secondSessionID = try await service.beginDrop(fileURL: secondURL)
        await recorder.resumeFirstSend()

        do {
            _ = try await firstBegin.value
            XCTFail("Expected the superseded begin to be cancelled")
        } catch is CancellationError {
            // Native-style supersession invalidates the first local begin operation.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(secondSessionID, 0x5678)
        XCTAssertTrue(history.entries.isEmpty)
        let messages = await recorder.messages
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages.allSatisfy { $0.first == 0x20 && $0.count > 16 })
    }

    func testRejectsNewDropWhileFileCopyIsActive() async throws {
        let firstURL = try makeTemporaryFile(contents: Data([0x41]))
        let secondURL = try makeTemporaryFile(contents: Data([0x42]))
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        let sender = PausingFileCopySender()
        let history = AppleFileTransferHistory()
        let service = AppleFileTransferService(
            remoteName: "Remote Mac",
            history: history,
            sender: sender,
            makeSessionID: { 0x1234 },
            send: { _ in }
        )

        _ = try await service.beginDrop(fileURL: firstURL)
        _ = await service.receive(type30Request())
        XCTAssertTrue(history.preventsNewDrop)

        await XCTAssertThrowsErrorAsync(try await service.beginDrop(fileURL: secondURL)) {
            XCTAssertEqual($0 as? AppleFileTransferServiceError, .transferAlreadyInProgress)
        }

        await service.close()
        sender.finish()
    }

    func testRejectsDropWithServiceErrorWhileObserving() async throws {
        let fileURL = try makeTemporaryFile(contents: Data())
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let service = AppleFileTransferService(
            remoteName: "Remote Mac",
            history: AppleFileTransferHistory(),
            sender: FakeFileCopySender(outputs: []),
            send: { _ in }
        )
        await service.setControlling(false)

        await XCTAssertThrowsErrorAsync(try await service.beginDrop(fileURL: fileURL)) {
            XCTAssertEqual($0 as? AppleFileTransferServiceError, .notControlling)
        }
    }

    func testCancellingPendingDropSendsNativeCancelAndAllowsAnotherDrop() async throws {
        let fileURL = try makeTemporaryFile(contents: Data())
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let recorder = FileTransferSendRecorder()
        let history = AppleFileTransferHistory()
        let service = AppleFileTransferService(
            remoteName: "Remote Mac",
            history: history,
            sender: FakeFileCopySender(outputs: []),
            makeSessionID: { 0x1234 },
            send: { messages in await recorder.record(messages) }
        )

        let sessionID = try await service.beginDrop(fileURL: fileURL)
        await service.cancelDrop(sessionID: sessionID)

        XCTAssertTrue(history.entries.isEmpty)
        let canAcceptDrop = await service.canAcceptDrop
        XCTAssertTrue(canAcceptDrop)
        let messages = await recorder.messages
        XCTAssertEqual(
            messages.last,
            try AppleFileTransferMessage.cancelDrop(sessionID: 0x1234)
        )
    }

    func testRejectsExpiredAndMismatchedFileRequests() async throws {
        let fileURL = try makeTemporaryFile(contents: Data())
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let uptime = LockedUptime()
        let history = AppleFileTransferHistory()
        let service = AppleFileTransferService(
            remoteName: "Remote Mac",
            history: history,
            sender: FakeFileCopySender(outputs: []),
            uptimeNanoseconds: { uptime.value },
            makeSessionID: { 0x1234 },
            send: { _ in }
        )

        _ = try await service.beginDrop(fileURL: fileURL)
        let receivedMismatch = await service.receive(type30Request(sessionID: 0x4321))
        XCTAssertTrue(receivedMismatch)
        XCTAssertTrue(history.entries.isEmpty)

        uptime.value = AppleFileTransferService.dropRequestLifetimeNanoseconds + 1
        let receivedExpiredRequest = await service.receive(type30Request())
        XCTAssertTrue(receivedExpiredRequest)
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testRemoteFailureBecomesTerminalOnlyAfterSenderFinishes() async throws {
        let fileURL = try makeTemporaryFile(contents: Data([0x58]))
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let history = AppleFileTransferHistory()
        let service = AppleFileTransferService(
            remoteName: "Remote Mac",
            history: history,
            sender: FakeFileCopySender(outputs: nativeSenderOutputs()),
            makeSessionID: { 0x1234 },
            send: { _ in }
        )

        _ = try await service.beginDrop(fileURL: fileURL)
        _ = await service.receive(type30Request())
        _ = await service.receive(completionResponse(errorCode: 7))
        await waitUntil {
            if case .failed = history.entries.first?.state { return true }
            return false
        }

        guard case .failed = history.entries.first?.state else {
            return XCTFail("Expected the remote failure to be visible")
        }
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if predicate() { return }
            try? await clock.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for file transfer state")
    }

    private func makeTemporaryFile(contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-transfer-\(UUID().uuidString).bin")
        try contents.write(to: url, options: .atomic)
        return url
    }

    private func type30Request(sessionID: UInt32 = 0x1234) -> Data {
        var message = Data([0x1e, 0, 0, 0])
        message.appendUInt32BE(sessionID)
        message.appendUInt32BE(4)
        message.append(Data("/tmp".utf8))
        return message
    }

    private func completionResponse(errorCode: UInt16) -> Data {
        let name = Data("file.bin".utf8)
        var body = Data()
        body.appendUInt16BE(1)
        body.appendUInt16BE(200)
        body.appendUInt32BE(0x1234)
        body.appendUInt16BE(errorCode)
        body.appendUInt16BE(UInt16(name.count))
        body.append(name)
        body.append(0)
        var message = Data([0x22, 0])
        message.appendUInt32BE(UInt32(body.count))
        message.append(body)
        return message
    }

    private func nativeSenderOutputs() -> [AppleFileCopyToolOutput] {
        let itemInfo = fileCopyFrame(command: 100, bodyLength: 60) { body in
            body.writeUInt32BE(1, at: 8)
            body.writeUInt64BE(1, at: 16)
            body.writeUInt64BE(1, at: 24)
            body.writeUInt64BE(1, at: 32)
        }
        let data = fileCopyFrame(command: 102, bodyLength: 13) { body in
            body.writeUInt32BE(1, at: 8)
            body[12] = 0x58
        }
        let done = fileCopyFrame(command: 104, bodyLength: 12) { _ in }
        return [
            .frame(itemInfo),
            .itemInfo(fileCopyToolItemInfo()),
            .frame(data),
            .frame(done),
            .finished(status: 0),
        ]
    }

    private func fileCopyToolItemInfo() -> Data {
        var message = Data(repeating: 0, count: 66)
        message[0] = 0x22
        message[2] = 60
        message.writeUInt16BE(1, at: 6)
        message.writeUInt16BE(100, at: 8)
        message.writeUInt32BE(0x1234, at: 10)
        message[22] = 1
        message[30] = 1
        message[38] = 1
        return message
    }

    private func fileCopyFrame(
        command: UInt16,
        bodyLength: Int,
        configure: (inout Data) -> Void
    ) -> Data {
        var body = Data(repeating: 0, count: bodyLength)
        body.writeUInt16BE(1, at: 0)
        body.writeUInt16BE(command, at: 2)
        body.writeUInt32BE(0x1234, at: 4)
        configure(&body)
        var message = Data([0x22, 0])
        message.appendUInt32BE(UInt32(body.count))
        message.append(body)
        return message
    }
}

private struct FakeFileCopySender: AppleFileCopySenderRunning {
    let outputsToYield: [AppleFileCopyToolOutput]
    let isAvailable = true

    init(outputs: [AppleFileCopyToolOutput]) {
        outputsToYield = outputs
    }

    func run(
        for fileURL: URL,
        sessionID: UInt32,
        receive: @escaping @Sendable (AppleFileCopyToolOutput) async throws -> Void
    ) async throws {
        for output in outputsToYield {
            try await receive(output)
        }
    }
}

private struct PausingFileCopySender: AppleFileCopySenderRunning {
    let isAvailable = true
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func run(
        for fileURL: URL,
        sessionID: UInt32,
        receive: @escaping @Sendable (AppleFileCopyToolOutput) async throws -> Void
    ) async throws {
        for await _ in stream {
            try Task.checkCancellation()
            return
        }
        try Task.checkCancellation()
    }

    func finish() {
        continuation.finish()
    }
}

private actor FileCopyToolOutputRecorder {
    private var outputs = [AppleFileCopyToolOutput]()

    func record(_ output: AppleFileCopyToolOutput) {
        outputs.append(output)
    }

    func result(sessionID: UInt32) throws -> (
        commands: [UInt16],
        itemInfoTotalBytes: UInt64?,
        finishedStatus: UInt16?
    ) {
        var commands = [UInt16]()
        var itemInfoTotalBytes: UInt64?
        var finishedStatus: UInt16?
        for output in outputs {
            switch output {
            case .frame(let message):
                commands.append(try AppleFileTransferMessage.senderFrame(
                    from: message,
                    expectedSessionID: sessionID
                ).command)
            case .itemInfo(let message):
                itemInfoTotalBytes = try AppleFileTransferMessage.senderItemInfo(
                    from: message,
                    expectedSessionID: sessionID
                ).totalBytes
            case .finished(let status):
                finishedStatus = status
            }
        }
        return (commands, itemInfoTotalBytes, finishedStatus)
    }
}

private actor FileTransferSendRecorder {
    private(set) var messages = [Data]()

    func record(_ messages: [Data]) {
        self.messages.append(contentsOf: messages)
    }
}

private actor SuspendedFirstSendRecorder {
    private(set) var messages = [Data]()
    private var didStartFirstSend = false
    private var firstSendContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters = [CheckedContinuation<Void, Never>]()

    func record(_ newMessages: [Data]) async {
        messages.append(contentsOf: newMessages)
        guard !didStartFirstSend else { return }
        didStartFirstSend = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            firstSendContinuation = continuation
        }
    }

    func waitUntilFirstSendStarts() async {
        if didStartFirstSend { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resumeFirstSend() {
        firstSendContinuation?.resume()
        firstSendContinuation = nil
    }
}

private final class LockedUptime: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: UInt64 = 0

    var value: UInt64 {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}

private final class LockedSessionIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt32]

    init(_ values: [UInt32]) {
        self.values = values
    }

    func next() -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        return values.removeFirst()
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ verify: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        verify(error)
    }
}
