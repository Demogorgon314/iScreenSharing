import Darwin
import Foundation
import ScreenSharingProtocol
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

    func testSwiftSenderMatchesNativeDirectoryAndSymlinkFrames() async throws {
        let native = AppleSystemFileCopySender()
        guard native.isAvailable else {
            throw XCTSkip("The native Screen Sharing file sender is unavailable.")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-transfer-tree-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("root".utf8).write(to: root.appendingPathComponent("root.txt"))
        try Data("nested".utf8).write(to: nested.appendingPathComponent("data.bin"))
        try FileManager.default.createSymbolicLink(
            atPath: nested.appendingPathComponent("relative-link").path,
            withDestinationPath: "../root.txt"
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let swiftOutputs = try await outputs(
            from: AppleSwiftFileCopySender(),
            fileURL: root
        )
        let nativeOutputs = try await outputs(from: native, fileURL: root)

        assertWireFramesEqual(swiftOutputs, nativeOutputs)
        XCTAssertEqual(finishedStatus(swiftOutputs), finishedStatus(nativeOutputs))
    }

    func testSwiftSenderMatchesNativeHardLinkNodeFlags() async throws {
        let native = AppleSystemFileCopySender()
        guard native.isAvailable else {
            throw XCTSkip("The native Screen Sharing file sender is unavailable.")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-transfer-hardlinks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let original = root.appendingPathComponent("original.bin")
        let hardLink = root.appendingPathComponent("hard-link.bin")
        try Data([0x58]).write(to: original)
        guard link(original.path, hardLink.path) == 0 else {
            throw NSError(domain: "CreateHardLink", code: Int(errno))
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let swiftOutputs = try await outputs(
            from: AppleSwiftFileCopySender(),
            fileURL: root
        )
        let nativeOutputs = try await outputs(from: native, fileURL: root)

        assertWireFramesEqual(swiftOutputs, nativeOutputs)
        let nodeFlags = swiftOutputs.compactMap { output -> UInt16? in
            guard case .frame(let message) = output,
                  let frame = try? AppleFileTransferMessage.receiverFrame(from: message),
                  case .item(let metadata) = frame.payload else { return nil }
            return metadata.nodeFlags
        }
        XCTAssertEqual(nodeFlags.filter { $0 & 0x100 != 0 }.count, 2)
    }

    func testSwiftSenderMatchesNativeRootSymlinkAndDanglingFailure() async throws {
        let native = AppleSystemFileCopySender()
        guard native.isAvailable else {
            throw XCTSkip("The native Screen Sharing file sender is unavailable.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-transfer-links-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("target")
        try Data("target-data".utf8).write(to: target)
        let validLink = directory.appendingPathComponent("valid-link")
        try FileManager.default.createSymbolicLink(
            atPath: validLink.path,
            withDestinationPath: "target"
        )
        let danglingLink = directory.appendingPathComponent("dangling-link")
        try FileManager.default.createSymbolicLink(
            atPath: danglingLink.path,
            withDestinationPath: "missing"
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        for fileURL in [validLink, danglingLink] {
            let swiftOutputs = try await outputs(
                from: AppleSwiftFileCopySender(),
                fileURL: fileURL
            )
            let nativeOutputs = try await outputs(from: native, fileURL: fileURL)
            assertWireFramesEqual(
                swiftOutputs,
                nativeOutputs,
                context: fileURL.lastPathComponent
            )
            XCTAssertEqual(
                finishedStatus(swiftOutputs),
                finishedStatus(nativeOutputs),
                fileURL.lastPathComponent
            )
        }
    }

    func testSwiftSenderMatchesNativeFinderInfoResourceForkAndExtendedAttributes() async throws {
        let native = AppleSystemFileCopySender()
        guard native.isAvailable else {
            throw XCTSkip("The native Screen Sharing file sender is unavailable.")
        }
        let fileURL = try makeTemporaryFile(contents: Data("data-fork".utf8))
        defer { try? FileManager.default.removeItem(at: fileURL) }
        var finderInfo = Data(repeating: 0, count: 32)
        finderInfo.replaceSubrange(0..<8, with: Data("alisMACS".utf8))
        finderInfo[8] = 0x80
        finderInfo[24] = 0x12
        finderInfo[25] = 0x34
        try setExtendedAttribute("com.apple.FinderInfo", value: finderInfo, at: fileURL)
        try setExtendedAttribute(
            "com.apple.ResourceFork",
            value: Data("resource-fork".utf8),
            at: fileURL
        )
        try setExtendedAttributeIfPermitted(
            "com.apple.quarantine",
            value: Data("0083;00000000;Safari;".utf8),
            at: fileURL
        )
        try setExtendedAttributeIfPermitted(
            "com.apple.metadata:kMDItemWhereFroms",
            value: Data([0x62, 0x70, 0x6c, 0x69, 0x73, 0x74, 0x30, 0x30]),
            at: fileURL
        )
        try setBackupTime(
            timespec(tv_sec: 1_700_000_000, tv_nsec: 0),
            at: fileURL
        )

        let swiftOutputs = try await outputs(
            from: AppleSwiftFileCopySender(),
            fileURL: fileURL
        )
        let nativeOutputs = try await outputs(from: native, fileURL: fileURL)

        assertWireFramesEqual(swiftOutputs, nativeOutputs)
        XCTAssertEqual(finishedStatus(swiftOutputs), finishedStatus(nativeOutputs))
    }

    func testCompressionPolicyMatchesNativeBacklogAndSavingsThresholds() {
        var policy = AppleFileCopyCompressionPolicy(startTick: 100)

        XCTAssertFalse(policy.shouldCompress(
            fileName: "archive.zip",
            pendingBytes: 10_000,
            totalBytesSent: 1_000,
            currentTick: 109
        ))
        XCTAssertFalse(policy.shouldCompress(
            fileName: "document.txt",
            pendingBytes: 0,
            totalBytesSent: 1_000,
            currentTick: 109
        ))
        XCTAssertFalse(policy.shouldCompress(
            fileName: "document.txt",
            pendingBytes: 10_000,
            totalBytesSent: 1_000,
            currentTick: 108
        ))
        XCTAssertFalse(policy.shouldCompress(
            fileName: "document.txt",
            pendingBytes: 1_800,
            totalBytesSent: 6_000,
            currentTick: 110
        ))
        XCTAssertTrue(policy.shouldCompress(
            fileName: "document.txt",
            pendingBytes: 1_801,
            totalBytesSent: 6_000,
            currentTick: 110
        ))

        for _ in 0..<6 {
            policy.recordCompressedBlock(inputBytes: 65_536, outputBytes: 65_000)
        }
        XCTAssertFalse(policy.shouldCompress(
            fileName: "document.txt",
            pendingBytes: 100_000,
            totalBytesSent: 6_000,
            currentTick: 110
        ))

        var wrappingPolicy = AppleFileCopyCompressionPolicy(startTick: UInt32.max - 4)
        XCTAssertTrue(wrappingPolicy.shouldCompress(
            fileName: "document.txt",
            pendingBytes: 1,
            totalBytesSent: 0,
            currentTick: 4
        ))
    }

    func testOutputPipePreservesOrderAndDrainsPendingBytes() async throws {
        let recorder = FileCopyToolOutputRecorder()
        let pipe = AppleFileCopyOutputPipe { output in
            await recorder.record(output)
        }
        let first = AppleFileCopyToolOutput.frame(Data([1, 2, 3]))
        let second = AppleFileCopyToolOutput.finished(status: 0)

        try await pipe.send(first)
        try await pipe.send(second)
        try await pipe.finish()

        let outputs = await recorder.outputs
        let metrics = await pipe.metrics()
        XCTAssertEqual(outputs, [first, second])
        XCTAssertEqual(metrics.pendingBytes, 0)
        XCTAssertEqual(metrics.totalBytesEnqueued, 15)
    }

    func testSwiftSenderUsesContinuousCompressionWhenNativeBacklogGateOpens() async throws {
        let fileURL = try makeTemporaryFile(
            contents: Data(String(repeating: "native-file-copy-", count: 28_000).utf8)
        )
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let ticks = FileCopyTickSource()
        let receiver = BlockingFirstFileCopyOutput()
        let sender = AppleSwiftFileCopySender(tickCount: { ticks.next() })

        let transfer = Task {
            try await sender.run(for: fileURL, sessionID: 0x1234) { output in
                await receiver.receive(output)
            }
        }
        await receiver.waitUntilFirstOutputStarts()
        await ticks.waitUntilCompressionIsChecked()
        await receiver.release()
        try await transfer.value

        let outputs = await receiver.outputs
        let commands = outputs.compactMap { output -> UInt16? in
            guard case .frame(let frame) = output, frame.count >= 10 else { return nil }
            return UInt16(frame[8]) << 8 | UInt16(frame[9])
        }
        XCTAssertTrue(commands.contains(103))
        XCTAssertEqual(commands.last, 104)
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
            makeFileCopySessionID: { 0x1234 },
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

    func testAllocatesFileCopySessionSeparatelyFromDragSession() async throws {
        let fileURL = try makeTemporaryFile(contents: Data([0x58]))
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let recorder = FileTransferSendRecorder()
        let sender = PausingFileCopySender()
        let service = AppleFileTransferService(
            remoteName: "Remote Mac",
            history: AppleFileTransferHistory(),
            sender: sender,
            makeSessionID: { 0x1234 },
            makeFileCopySessionID: { 0x5678 },
            send: { messages in await recorder.record(messages) }
        )

        let dragSessionID = try await service.beginDrop(fileURL: fileURL)
        XCTAssertEqual(dragSessionID, 0x1234)
        _ = await service.receive(type30Request(sessionID: 0x1234))
        let expectedStart = try AppleFileTransferMessage.startFileReceive(
            sessionID: 0x5678,
            destinationPath: "/tmp"
        )
        await waitUntilAsync { (await recorder.messages).contains(expectedStart) }

        await service.close()
        sender.finish()
    }

    func testAcceptsDirectoryAndSymbolicLinkDrops() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-transfer-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("target")
        try Data("target".utf8).write(to: target)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "target"
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        for fileURL in [directory, link] {
            let service = AppleFileTransferService(
                remoteName: "Remote Mac",
                history: AppleFileTransferHistory(),
                sender: FakeFileCopySender(outputs: []),
                makeSessionID: { 0x1234 },
                send: { _ in }
            )

            let sessionID = try await service.beginDrop(fileURL: fileURL)
            XCTAssertEqual(sessionID, 0x1234)
            await service.close()
        }
    }

    func testMultipleDroppedRootsShareDragAndStartIndependentFileCopies() async throws {
        let firstURL = try makeTemporaryFile(contents: Data([0x41]))
        let secondURL = try makeTemporaryFile(contents: Data([0x42]))
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        let sender = PausingFileCopySender()
        let recorder = FileTransferSendRecorder()
        let allocatedSessionIDs = LockedSessionIDs([1, 2])
        let history = AppleFileTransferHistory()
        let service = AppleFileTransferService(
            remoteName: "Remote Mac",
            history: history,
            sender: sender,
            makeSessionID: { 0x1234 },
            makeFileCopySessionID: { allocatedSessionIDs.next() },
            send: { messages in await recorder.record(messages) }
        )

        _ = try await service.beginDrop(fileURLs: [firstURL, secondURL])
        let sentMessages = await recorder.messages
        let dragMessage = try XCTUnwrap(sentMessages.first)
        XCTAssertEqual(
            try AppleFileTransferMessage.remoteDrag(from: dragMessage)?.sourcePaths,
            [firstURL.standardizedFileURL.path, secondURL.standardizedFileURL.path]
        )
        _ = await service.receive(type30Request())
        await waitUntil { history.entries.count == 2 }
        await waitUntilAsync {
            await self.fileCopySessionIDs(command: 2, in: recorder).count == 2
        }
        let startedSessionIDs = await self.fileCopySessionIDs(command: 2, in: recorder)
        XCTAssertEqual(startedSessionIDs, [1, 2])

        await service.close()
        sender.finish()
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

    func testAllowsAnotherDropWhileFileCopyIsActive() async throws {
        let firstURL = try makeTemporaryFile(contents: Data([0x41]))
        let secondURL = try makeTemporaryFile(contents: Data([0x42]))
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        let sender = PausingFileCopySender()
        let sessionIDs = LockedSessionIDs([0x1234, 0x5678])
        let history = AppleFileTransferHistory()
        let service = AppleFileTransferService(
            remoteName: "Remote Mac",
            history: history,
            sender: sender,
            makeSessionID: { sessionIDs.next() },
            send: { _ in }
        )

        _ = try await service.beginDrop(fileURL: firstURL)
        _ = await service.receive(type30Request())

        let secondSessionID = try await service.beginDrop(fileURL: secondURL)
        XCTAssertEqual(secondSessionID, 0x5678)

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

    func testSemanticInvalidMatchingFileRequestClearsPendingDrop() async throws {
        let fileURL = try makeTemporaryFile(contents: Data([0x58]))
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let sender = PausingFileCopySender()
        let recorder = FileTransferSendRecorder()
        let history = AppleFileTransferHistory()
        let service = AppleFileTransferService(
            remoteName: "Remote Mac",
            history: history,
            sender: sender,
            makeSessionID: { 0x1234 },
            send: { messages in await recorder.record(messages) }
        )
        _ = try await service.beginDrop(fileURL: fileURL)
        var invalidRequest = Data([0x1e, 0, 0, 0])
        invalidRequest.appendUInt32BE(0x1234)
        invalidRequest.appendUInt32BE(0)

        let acceptedInvalidRequest = await service.receive(invalidRequest)
        let acceptedLaterRequest = await service.receive(type30Request())
        XCTAssertTrue(acceptedInvalidRequest)
        XCTAssertTrue(acceptedLaterRequest)
        await Task.yield()

        XCTAssertTrue(history.entries.isEmpty)
        let startedSessionIDs = await self.fileCopySessionIDs(command: 2, in: recorder)
        XCTAssertTrue(startedSessionIDs.isEmpty)
        await service.close()
        sender.finish()
    }

    func testSemanticInvalidMatchingCompletionFailsActiveTransfer() async throws {
        let fileURL = try makeTemporaryFile(contents: Data([0x58]))
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let history = AppleFileTransferHistory()
        let service = AppleFileTransferService(
            remoteName: "Remote Mac",
            history: history,
            sender: FakeFileCopySender(outputs: nativeSenderOutputs()),
            makeSessionID: { 0x1234 },
            makeFileCopySessionID: { 0x1234 },
            send: { _ in }
        )
        _ = try await service.beginDrop(fileURL: fileURL)
        _ = await service.receive(type30Request())
        await waitUntil { history.entries.first?.state == .completing }
        var invalidCompletion = Data([0x22, 0])
        invalidCompletion.appendUInt32BE(8)
        invalidCompletion.appendUInt16BE(1)
        invalidCompletion.appendUInt16BE(200)
        invalidCompletion.appendUInt32BE(0x1234)

        let acceptedInvalidCompletion = await service.receive(invalidCompletion)
        XCTAssertTrue(acceptedInvalidCompletion)
        await waitUntil {
            if case .failed = history.entries.first?.state { return true }
            return false
        }
    }

    func testCancellingActiveOutgoingTransferSendsStopAndUpdatesHistory() async throws {
        let fileURL = try makeTemporaryFile(contents: Data([0x58]))
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let sender = PausingFileCopySender()
        let recorder = FileTransferSendRecorder()
        let history = AppleFileTransferHistory()
        let service = AppleFileTransferService(
            remoteName: "Remote Mac",
            history: history,
            sender: sender,
            makeSessionID: { 0x1234 },
            makeFileCopySessionID: { 1 },
            send: { messages in await recorder.record(messages) }
        )
        _ = try await service.beginDrop(fileURL: fileURL)
        _ = await service.receive(type30Request())
        await waitUntil { history.entries.first?.state == .sending }
        let historyID = try XCTUnwrap(history.entries.first?.id)

        await service.cancelTransfer(historyID: historyID)

        XCTAssertEqual(history.entries.first?.state, .cancelled)
        let stoppedSessionIDs = await self.fileCopySessionIDs(command: 5, in: recorder)
        XCTAssertEqual(stoppedSessionIDs, [1])
        sender.finish()
    }

    func testPausesAndResumesActiveOutgoingTransferWithNativeCommands() async throws {
        let fileURL = try makeTemporaryFile(contents: Data([0x58]))
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let sender = PausingFileCopySender()
        let recorder = FileTransferSendRecorder()
        let history = AppleFileTransferHistory()
        let service = AppleFileTransferService(
            remoteName: "Remote Mac",
            history: history,
            sender: sender,
            makeSessionID: { 0x1234 },
            makeFileCopySessionID: { 1 },
            send: { messages in await recorder.record(messages) }
        )
        _ = try await service.beginDrop(fileURL: fileURL)
        _ = await service.receive(type30Request())
        await waitUntil { history.entries.first?.state == .sending }
        let historyID = try XCTUnwrap(history.entries.first?.id)

        await service.setTransferPaused(historyID: historyID, paused: true)
        XCTAssertEqual(history.entries.first?.state, .paused)
        let pausedSessionIDs = await fileCopySessionIDs(command: 3, in: recorder)
        XCTAssertEqual(pausedSessionIDs, [1])

        await service.setTransferPaused(historyID: historyID, paused: false)
        XCTAssertEqual(history.entries.first?.state, .sending)
        let resumedSessionIDs = await fileCopySessionIDs(command: 4, in: recorder)
        XCTAssertEqual(resumedSessionIDs, [1])

        await service.cancelTransfer(historyID: historyID)
        sender.finish()
    }

    func testPausedOutgoingTransferBackpressuresLocalSender() async throws {
        let fileURL = try makeTemporaryFile(contents: Data([0x58]))
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let outputs = nativeSenderOutputs()
        guard case .frame(let summary) = outputs[0],
              case .frame(let item) = outputs[2],
              case .frame(let done) = outputs[3] else {
            return XCTFail("Expected native sender frames")
        }
        let sender = ManualFileCopySender()
        let recorder = FileTransferSendRecorder()
        let history = AppleFileTransferHistory()
        let service = AppleFileTransferService(
            remoteName: "Remote Mac",
            history: history,
            sender: sender,
            makeSessionID: { 0x1234 },
            makeFileCopySessionID: { 0x1234 },
            send: { messages in await recorder.record(messages) }
        )
        _ = try await service.beginDrop(fileURL: fileURL)
        _ = await service.receive(type30Request())
        await sender.waitUntilReady()
        try await sender.emit(.frame(summary))
        let historyID = try XCTUnwrap(history.entries.first?.id)

        await service.setTransferPaused(historyID: historyID, paused: true)
        let itemEmission = Task { try await sender.emit(.frame(item)) }
        for _ in 0..<10 { await Task.yield() }

        let itemSessionIDsWhilePaused = await fileCopySessionIDs(command: 102, in: recorder)
        XCTAssertTrue(itemSessionIDsWhilePaused.isEmpty)

        await service.setTransferPaused(historyID: historyID, paused: false)
        try await itemEmission.value
        let itemSessionIDsAfterResume = await fileCopySessionIDs(command: 102, in: recorder)
        XCTAssertEqual(itemSessionIDsAfterResume, [0x1234])

        await service.setTransferPaused(historyID: historyID, paused: true)
        let doneEmission = Task { try await sender.emit(.frame(done)) }
        for _ in 0..<10 { await Task.yield() }
        let doneSessionIDsWhilePaused = await fileCopySessionIDs(command: 104, in: recorder)
        XCTAssertTrue(doneSessionIDsWhilePaused.isEmpty)

        await service.cancelTransfer(historyID: historyID)
        await XCTAssertThrowsErrorAsync(try await doneEmission.value) {
            XCTAssertTrue($0 is CancellationError)
        }
        await sender.finish()
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
            makeFileCopySessionID: { 0x1234 },
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

    func testReassemblesRemoteDragAndClearsItWithNativeEmptyMessage() async throws {
        let fileURL = URL(fileURLWithPath: "/remote/Folder/file.txt")
        let archive = AppleClipboardArchive(items: [
            AppleClipboardItem(flavors: [
                AppleClipboardFlavor(
                    type: "public.file-url",
                    aliases: [
                        AppleClipboardTypeAlias(
                            tagClass: "com.apple.ostype",
                            preferredTag: "furl"
                        )
                    ],
                    value: Data(fileURL.absoluteString.utf8)
                )
            ])
        ])
        var message = try AppleClipboardMessage.send(archive: archive, sessionID: 0x1234)
        message[0] = 0x20
        let service = AppleFileTransferService(
            remoteName: "Remote Mac",
            history: AppleFileTransferHistory(),
            sender: FakeFileCopySender(outputs: []),
            send: { _ in }
        )

        let acceptedFirstFragment = await service.receive(message.prefix(20))
        XCTAssertTrue(acceptedFirstFragment)
        XCTAssertNil(service.remoteDrag.drag)
        let acceptedSecondFragment = await service.receive(message.dropFirst(20))
        XCTAssertTrue(acceptedSecondFragment)
        XCTAssertEqual(service.remoteDrag.drag?.sourcePaths, [fileURL.path])

        let acceptedClear = await service.receive(
            try AppleFileTransferMessage.cancelDrop(sessionID: 0x4321)
        )
        XCTAssertTrue(acceptedClear)
        XCTAssertNil(service.remoteDrag.drag)

        await service.close()
        let acceptedLateDrag = await service.receive(message)
        XCTAssertTrue(acceptedLateDrag)
        XCTAssertNil(service.remoteDrag.drag)
    }

    func testRemoteDragExpiresAfterNativeLifetime() async throws {
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
        let sleeper = ControlledFileTransferSleep()
        let service = AppleFileTransferService(
            remoteName: "Remote Mac",
            history: AppleFileTransferHistory(),
            sender: FakeFileCopySender(outputs: []),
            sleep: { duration in try await sleeper.sleep(duration) },
            send: { _ in }
        )

        let accepted = await service.receive(message)
        XCTAssertTrue(accepted)
        XCTAssertNotNil(service.remoteDrag.drag)
        await sleeper.waitUntilStarted()
        await sleeper.resume()
        await waitUntil { service.remoteDrag.drag == nil }
    }

    func testReceivesRemoteFileFromFragmentedType34Frames() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("incoming-file-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("file.bin")
        let recorder = FileTransferSendRecorder()
        let history = AppleFileTransferHistory()
        let service = AppleFileTransferService(
            remoteName: "Remote Mac",
            history: history,
            sender: FakeFileCopySender(outputs: []),
            makeFileCopySessionID: { 1 },
            send: { messages in await recorder.record(messages) }
        )
        let receiveTask = Task {
            try await service.receiveRemoteFile(
                sourcePath: "/remote/file.bin",
                destinationURL: destination
            )
        }
        await waitUntilAsync { !(await recorder.messages).isEmpty }
        let startMessages = await recorder.messages
        XCTAssertEqual(startMessages.count, 1)
        XCTAssertEqual(startMessages[0], try AppleFileTransferMessage.startFileSend(
            sessionID: 1,
            sourcePath: "/remote/file.bin"
        ))

        let summary = try AppleFileTransferMessage.senderSummary(
            sessionID: 1,
            summary: AppleFileCopySummary(
                rootIsFile: true,
                logicalBytes: 1,
                physicalBytes: 4_096,
                fileCount: 1,
                folderCount: 0
            )
        )
        let item = try AppleFileTransferMessage.senderItem(
            sessionID: 1,
            item: AppleFileCopyItemMetadata(
                type: .file,
                finderInfo: Data(repeating: 0, count: 32),
                resourceForkSize: 0,
                dataForkSize: 1,
                creationDate: .zero,
                contentModificationDate: .zero,
                attributeModificationDate: .zero,
                accessDate: .zero,
                nodeFlags: 0,
                level: 0,
                mode: 0o100600,
                textEncodingHint: 0x7e,
                name: "remote.bin"
            )
        )
        let data = try AppleFileTransferMessage.senderData(
            sessionID: 1,
            data: Data([0x58])
        )
        let done = try AppleFileTransferMessage.senderDone(sessionID: 1, status: 0)
        let acceptedSummary = await service.receive(summary)
        let acceptedItem = await service.receive(item)
        let acceptedFirstDataFragment = await service.receive(data.prefix(10))
        let acceptedSecondDataFragment = await service.receive(data.dropFirst(10))
        let acceptedDone = await service.receive(done)
        XCTAssertTrue(acceptedSummary)
        XCTAssertTrue(acceptedItem)
        XCTAssertTrue(acceptedFirstDataFragment)
        XCTAssertTrue(acceptedSecondDataFragment)
        XCTAssertTrue(acceptedDone)

        let receivedURL = try await receiveTask.value
        XCTAssertEqual(receivedURL, destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data([0x58]))
        XCTAssertEqual(history.entries.first?.direction, .fromRemote)
        XCTAssertEqual(history.entries.first?.state, .received)
        XCTAssertEqual(history.entries.first?.progress, 1)
    }

    func testQueuesMoreThanFourRemoteReceivesInFIFOOrder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("queued-incoming-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = FileTransferSendRecorder()
        let history = AppleFileTransferHistory()
        let sessionIDs = LockedSessionIDs([1, 2, 3, 4, 5])
        let service = AppleFileTransferService(
            remoteName: "Remote Mac",
            history: history,
            sender: FakeFileCopySender(outputs: []),
            makeFileCopySessionID: { sessionIDs.next() },
            send: { messages in await recorder.record(messages) }
        )
        var tasks = [Task<URL, Error>]()
        for index in 0..<5 {
            let destination = directory.appendingPathComponent("file-\(index).bin")
            tasks.append(Task {
                try await service.receiveRemoteFile(
                    sourcePath: "/remote/file-\(index).bin",
                    destinationURL: destination
                )
            })
        }
        await waitUntil { history.entries.count == 5 }
        await waitUntilAsync {
            await self.startFileSendSessionIDs(in: recorder).count == 4
        }

        let firstStartedSessionIDs = await startFileSendSessionIDs(in: recorder)
        XCTAssertEqual(firstStartedSessionIDs, [1, 2, 3, 4])
        tasks[0].cancel()
        await XCTAssertThrowsErrorAsync(try await tasks[0].value) {
            XCTAssertTrue($0 is CancellationError)
        }
        await waitUntilAsync {
            await self.startFileSendSessionIDs(in: recorder).count == 5
        }
        let allStartedSessionIDs = await startFileSendSessionIDs(in: recorder)
        XCTAssertEqual(allStartedSessionIDs, [1, 2, 3, 4, 5])

        await service.close()
        for task in tasks.dropFirst() {
            _ = try? await task.value
        }
    }

    func testRunsIncomingAndOutgoingTransfersConcurrently() async throws {
        let outgoingURL = try makeTemporaryFile(contents: Data([0x41]))
        let incomingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("full-duplex-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: incomingDirectory,
            withIntermediateDirectories: false
        )
        defer {
            try? FileManager.default.removeItem(at: outgoingURL)
            try? FileManager.default.removeItem(at: incomingDirectory)
        }
        let sender = PausingFileCopySender()
        let recorder = FileTransferSendRecorder()
        let allocatedSessionIDs = LockedSessionIDs([1, 2])
        let service = AppleFileTransferService(
            remoteName: "Remote Mac",
            history: AppleFileTransferHistory(),
            sender: sender,
            makeSessionID: { 0x1234 },
            makeFileCopySessionID: { allocatedSessionIDs.next() },
            send: { messages in await recorder.record(messages) }
        )

        _ = try await service.beginDrop(fileURL: outgoingURL)
        _ = await service.receive(type30Request())
        await waitUntilAsync {
            await self.fileCopySessionIDs(command: 2, in: recorder) == [1]
        }

        let receiveTask = Task {
            try await service.receiveRemoteFile(
                sourcePath: "/remote/incoming.bin",
                destinationURL: incomingDirectory.appendingPathComponent("incoming.bin")
            )
        }
        await waitUntilAsync {
            await self.fileCopySessionIDs(command: 1, in: recorder) == [2]
        }

        await service.close()
        sender.finish()
        await XCTAssertThrowsErrorAsync(try await receiveTask.value) {
            XCTAssertEqual($0 as? AppleFileTransferServiceError, .closed)
        }
    }

    func testPausesAndResumesActiveIncomingTransferWithNativeCommands() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("paused-incoming-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = FileTransferSendRecorder()
        let history = AppleFileTransferHistory()
        let service = AppleFileTransferService(
            remoteName: "Remote Mac",
            history: history,
            sender: FakeFileCopySender(outputs: []),
            makeFileCopySessionID: { 1 },
            send: { messages in await recorder.record(messages) }
        )
        let receiveTask = Task {
            try await service.receiveRemoteFile(
                sourcePath: "/remote/file.bin",
                destinationURL: directory.appendingPathComponent("file.bin")
            )
        }
        await waitUntil { history.entries.first?.state == .receiving }
        let historyID = try XCTUnwrap(history.entries.first?.id)

        await service.setTransferPaused(historyID: historyID, paused: true)
        XCTAssertEqual(history.entries.first?.state, .paused)
        let pausedSessionIDs = await fileCopySessionIDs(command: 3, in: recorder)
        XCTAssertEqual(pausedSessionIDs, [1])

        await service.setTransferPaused(historyID: historyID, paused: false)
        XCTAssertEqual(history.entries.first?.state, .receiving)
        let resumedSessionIDs = await fileCopySessionIDs(command: 4, in: recorder)
        XCTAssertEqual(resumedSessionIDs, [1])

        await service.cancelTransfer(historyID: historyID)
        await XCTAssertThrowsErrorAsync(try await receiveTask.value) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testCancellingRemoteReceiveDuringStartDoesNotResurrectTransfer() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancelled-incoming-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = SuspendedFirstSendRecorder()
        let history = AppleFileTransferHistory()
        let service = AppleFileTransferService(
            remoteName: "Remote Mac",
            history: history,
            sender: FakeFileCopySender(outputs: []),
            makeFileCopySessionID: { 1 },
            send: { messages in await recorder.record(messages) }
        )
        let receiveTask = Task {
            try await service.receiveRemoteFile(
                sourcePath: "/remote/file.bin",
                destinationURL: directory.appendingPathComponent("file.bin")
            )
        }
        await recorder.waitUntilFirstSendStarts()

        receiveTask.cancel()
        await waitUntil { history.entries.first?.state == .cancelled }
        await recorder.resumeFirstSend()
        await XCTAssertThrowsErrorAsync(try await receiveTask.value) {
            XCTAssertTrue($0 is CancellationError)
        }
        await Task.yield()
        XCTAssertEqual(history.entries.first?.state, .cancelled)
    }

    func testOversizedRemoteFrameFailsMatchingTransferInsteadOfHanging() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oversized-incoming-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = FileTransferSendRecorder()
        let service = AppleFileTransferService(
            remoteName: "Remote Mac",
            history: AppleFileTransferHistory(),
            sender: FakeFileCopySender(outputs: []),
            makeFileCopySessionID: { 1 },
            send: { messages in await recorder.record(messages) }
        )
        let receiveTask = Task {
            try await service.receiveRemoteFile(
                sourcePath: "/remote/file.bin",
                destinationURL: directory.appendingPathComponent("file.bin")
            )
        }
        await waitUntilAsync { !(await recorder.messages).isEmpty }
        var oversized = Data(repeating: 0, count: 14)
        oversized[0] = 0x22
        oversized.writeUInt32BE(
            UInt32(AppleFileTransferMessage.maximumFileCopyBodyLength + 1),
            at: 2
        )
        oversized.writeUInt32BE(1, at: 10)

        let acceptedOversizedFrame = await service.receive(oversized)
        XCTAssertTrue(acceptedOversizedFrame)
        await XCTAssertThrowsErrorAsync(try await receiveTask.value) {
            XCTAssertEqual(
                $0 as? AppleFileTransferServiceError,
                .invalidSenderOutput
            )
        }
        let messages = await recorder.messages
        let stop = try AppleFileTransferMessage.control(sessionID: 1, action: .stop)
        XCTAssertTrue(messages.contains(stop))
    }

    func testRemoteDoneFailureLeavesPartialFileWithoutSendingStop() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("failed-incoming-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("file.bin")
        let recorder = FileTransferSendRecorder()
        let history = AppleFileTransferHistory()
        let service = AppleFileTransferService(
            remoteName: "Remote Mac",
            history: history,
            sender: FakeFileCopySender(outputs: []),
            makeFileCopySessionID: { 1 },
            send: { messages in await recorder.record(messages) }
        )
        let receiveTask = Task {
            try await service.receiveRemoteFile(
                sourcePath: "/remote/file.bin",
                destinationURL: destination
            )
        }
        await waitUntilAsync { !(await recorder.messages).isEmpty }
        _ = await service.receive(try AppleFileTransferMessage.senderSummary(
            sessionID: 1,
            summary: AppleFileCopySummary(
                rootIsFile: true,
                logicalBytes: 2,
                physicalBytes: 4_096,
                fileCount: 1,
                folderCount: 0
            )
        ))
        _ = await service.receive(try AppleFileTransferMessage.senderItem(
            sessionID: 1,
            item: AppleFileCopyItemMetadata(
                type: .file,
                finderInfo: Data(repeating: 0, count: 32),
                resourceForkSize: 0,
                dataForkSize: 2,
                creationDate: .zero,
                contentModificationDate: .zero,
                attributeModificationDate: .zero,
                accessDate: .zero,
                nodeFlags: 0,
                level: 0,
                mode: 0o100600,
                textEncodingHint: 0x7e,
                name: "file.bin"
            )
        ))
        _ = await service.receive(try AppleFileTransferMessage.senderData(
            sessionID: 1,
            data: Data([0x58])
        ))
        _ = await service.receive(try AppleFileTransferMessage.senderDone(
            sessionID: 1,
            status: -5_000
        ))

        await XCTAssertThrowsErrorAsync(try await receiveTask.value) {
            XCTAssertEqual(
                $0 as? AppleSwiftFileCopyReceiverError,
                .remoteFailed(-5_000)
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let messages = await recorder.messages
        XCTAssertFalse(messages.contains { message in
            message.count >= 10 && message[8] == 0 && message[9] == 5
        })
        guard case .failed = history.entries.first?.state else {
            return XCTFail("Expected a failed incoming transfer")
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

    private func waitUntilAsync(
        _ predicate: @escaping () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if await predicate() { return }
            try? await clock.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for asynchronous file transfer state")
    }

    nonisolated private func startFileSendSessionIDs(
        in recorder: FileTransferSendRecorder
    ) async -> [UInt32] {
        await fileCopySessionIDs(command: 1, in: recorder)
    }

    nonisolated private func fileCopySessionIDs(
        command: UInt16,
        in recorder: FileTransferSendRecorder
    ) async -> [UInt32] {
        await recorder.messages.compactMap { message in
            guard message.count >= 14,
                  message[0] == 0x22,
                  (UInt16(message[8]) << 8 | UInt16(message[9])) == command else { return nil }
            return UInt32(message[10]) << 24 | UInt32(message[11]) << 16
                | UInt32(message[12]) << 8 | UInt32(message[13])
        }
    }

    private func makeTemporaryFile(contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-transfer-\(UUID().uuidString).bin")
        try contents.write(to: url, options: .atomic)
        return url
    }

    private func setExtendedAttribute(
        _ name: String,
        value: Data,
        at fileURL: URL
    ) throws {
        let result = value.withUnsafeBytes { bytes in
            fileURL.path.withCString { path in
                name.withCString { attributeName in
                    setxattr(path, attributeName, bytes.baseAddress, bytes.count, 0, 0)
                }
            }
        }
        guard result == 0 else {
            throw NSError(
                domain: "SetExtendedAttribute.\(name)",
                code: Int(errno)
            )
        }
    }

    private func setExtendedAttributeIfPermitted(
        _ name: String,
        value: Data,
        at fileURL: URL
    ) throws {
        do {
            try setExtendedAttribute(name, value: value, at: fileURL)
        } catch let error as NSError where error.code == Int(EPERM) {
            // The app-sandboxed test host cannot create quarantine metadata.
            // FinderInfo/resource-fork coverage remains mandatory above.
        }
    }

    private func setBackupTime(_ value: timespec, at fileURL: URL) throws {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_BKUPTIME)
        var value = value
        let result = withUnsafeMutableBytes(of: &value) { bytes in
            setattrlist(
                fileURL.path,
                &attributes,
                bytes.baseAddress,
                bytes.count,
                UInt32(FSOPT_NOFOLLOW)
            )
        }
        guard result == 0 else {
            throw NSError(domain: "SetBackupTime", code: Int(errno))
        }
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

    private func outputs(
        from sender: any AppleFileCopySenderRunning,
        fileURL: URL
    ) async throws -> [AppleFileCopyToolOutput] {
        let recorder = FileCopyToolOutputRecorder()
        try await sender.run(for: fileURL, sessionID: 0x1234) { output in
            await recorder.record(output)
        }
        return await recorder.outputs
    }

    private func normalizedWireFrames(
        _ outputs: [AppleFileCopyToolOutput]
    ) -> [Data] {
        outputs.compactMap { output in
            guard case .frame(var frame) = output else { return nil }
            guard frame.count >= 104,
                  frame[0] == 0x22,
                  frame[8] == 0,
                  frame[9] == 101 else { return frame }
            // Reading the data fork can advance atime between the Swift and
            // native runs. The other four UTCDateTime fields must still match.
            frame.replaceSubrange(88..<96, with: repeatElement(UInt8(0), count: 8))
            return frame
        }
    }

    private func assertWireFramesEqual(
        _ swiftOutputs: [AppleFileCopyToolOutput],
        _ nativeOutputs: [AppleFileCopyToolOutput],
        context: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let swiftFrames = normalizedWireFrames(swiftOutputs)
        let nativeFrames = normalizedWireFrames(nativeOutputs)
        guard swiftFrames.count == nativeFrames.count else {
            return XCTFail(
                "\(context) frame count differs: Swift \(swiftFrames.count), native \(nativeFrames.count)",
                file: file,
                line: line
            )
        }
        let differences: [String] = zip(swiftFrames, nativeFrames).enumerated().compactMap {
            element -> String? in
            let (index, frames) = element
            guard frames.0 != frames.1 else { return nil }
            let sharedCount = min(frames.0.count, frames.1.count)
            let differingOffset = (0..<sharedCount).first { frames.0[$0] != frames.1[$0] }
            if let differingOffset {
                return "frame \(index) byte \(differingOffset) "
                    + "Swift=0x\(String(frames.0[differingOffset], radix: 16)) "
                    + "native=0x\(String(frames.1[differingOffset], radix: 16))"
            }
            return "frame \(index) length Swift=\(frames.0.count) native=\(frames.1.count)"
        }
        if !differences.isEmpty {
            XCTFail(
                ([context] + differences).filter { !$0.isEmpty }.joined(separator: "; "),
                file: file,
                line: line
            )
        }
    }

    private func finishedStatus(_ outputs: [AppleFileCopyToolOutput]) -> UInt16? {
        outputs.compactMap { output in
            guard case .finished(let status) = output else { return nil }
            return status
        }.last
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

/// Test-only adapter for comparing the Swift encoder with Apple's runtime oracle.
/// Production file transfers never launch this private executable.
private struct AppleSystemFileCopySender: AppleFileCopySenderRunning {
    private static let executableURL = URL(fileURLWithPath:
        "/System/Library/PrivateFrameworks/ScreenSharing.framework/Versions/A/Resources/SSFileCopySenderFW"
    )

    var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: Self.executableURL.path)
    }

    func run(
        for fileURL: URL,
        sessionID: UInt32,
        receive: @escaping @Sendable (AppleFileCopyToolOutput) async throws -> Void
    ) async throws {
        guard isAvailable else { throw AppleFileTransferServiceError.unavailable }
        let path = Data(fileURL.path.utf8)
        guard !path.isEmpty, path.count <= Int(UInt16.max), !path.contains(0) else {
            throw AppleFileTransferServiceError.unsupportedItem
        }
        var request = Data()
        request.appendUInt16LE(1)
        request.appendUInt32LE(sessionID)
        request.appendUInt16LE(UInt16(path.count))
        request.append(path)
        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        process.executableURL = Self.executableURL
        process.arguments = [String(getuid()), String(getgid())]
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice
        let worker = Task.detached(priority: .userInitiated) {
            do {
                try process.run()
                try standardInput.fileHandleForWriting.write(contentsOf: request)
                try standardInput.fileHandleForWriting.close()

                var parser = AppleFileCopyToolMessageParser()
                while !Task.isCancelled,
                      let bytes = try standardOutput.fileHandleForReading.read(upToCount: 65_536),
                      !bytes.isEmpty {
                    for message in try parser.process(bytes) {
                        try await receive(message)
                    }
                }
                if Task.isCancelled { throw CancellationError() }
                process.waitUntilExit()
                try parser.finish()
                guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                    throw AppleFileTransferServiceError.senderFailed
                }
            } catch {
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                }
                throw error
            }
        }
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
            if process.isRunning { process.terminate() }
        }
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

private actor ManualFileCopySender: AppleFileCopySenderRunning {
    nonisolated let isAvailable = true
    private var receiveHandler: (@Sendable (AppleFileCopyToolOutput) async throws -> Void)?
    private var readyWaiters = [CheckedContinuation<Void, Never>]()
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func run(
        for fileURL: URL,
        sessionID: UInt32,
        receive: @escaping @Sendable (AppleFileCopyToolOutput) async throws -> Void
    ) async throws {
        receiveHandler = receive
        let waiters = readyWaiters
        readyWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
        try Task.checkCancellation()
    }

    func waitUntilReady() async {
        guard receiveHandler == nil else { return }
        await withCheckedContinuation { continuation in
            readyWaiters.append(continuation)
        }
    }

    func emit(_ output: AppleFileCopyToolOutput) async throws {
        guard let receiveHandler else {
            throw AppleFileTransferServiceError.senderFailed
        }
        try await receiveHandler(output)
    }

    func finish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

private actor FileCopyToolOutputRecorder {
    private var recordedOutputs = [AppleFileCopyToolOutput]()

    func record(_ output: AppleFileCopyToolOutput) {
        recordedOutputs.append(output)
    }

    var outputs: [AppleFileCopyToolOutput] { recordedOutputs }

    func result(sessionID: UInt32) throws -> (
        commands: [UInt16],
        itemInfoTotalBytes: UInt64?,
        finishedStatus: UInt16?
    ) {
        var commands = [UInt16]()
        var itemInfoTotalBytes: UInt64?
        var finishedStatus: UInt16?
        for output in recordedOutputs {
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

private actor BlockingFirstFileCopyOutput {
    private(set) var outputs = [AppleFileCopyToolOutput]()
    private var didStartFirstOutput = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters = [CheckedContinuation<Void, Never>]()

    func receive(_ output: AppleFileCopyToolOutput) async {
        outputs.append(output)
        guard !didStartFirstOutput else { return }
        didStartFirstOutput = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilFirstOutputStarts() async {
        if didStartFirstOutput { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class FileCopyTickSource: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private var compressionWaiters = [CheckedContinuation<Void, Never>]()

    func next() -> UInt32 {
        let result = lock.withLock { () -> (UInt32, [CheckedContinuation<Void, Never>]) in
            callCount += 1
            guard callCount >= 2 else { return (0, []) }
            let waiters = compressionWaiters
            compressionWaiters.removeAll()
            return (10, waiters)
        }
        result.1.forEach { $0.resume() }
        return result.0
    }

    func waitUntilCompressionIsChecked() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                guard callCount < 2 else { return true }
                compressionWaiters.append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
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

private actor ControlledFileTransferSleep {
    private var continuation: CheckedContinuation<Void, Error>?
    private var startWaiters = [CheckedContinuation<Void, Never>]()

    func sleep(_ duration: Duration) async throws {
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
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

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
