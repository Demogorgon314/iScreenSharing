import Foundation
import enum ScreenSharingProtocol.AppleFileCopyToolOutput
import enum ScreenSharingProtocol.AppleFileTransferMessage
import enum ScreenSharingProtocol.AppleFileTransferResponse
import struct ScreenSharingProtocol.AppleFileCopyFrame
import struct ScreenSharingProtocol.AppleFileCopyToolMessageParser
import struct ScreenSharingProtocol.AppleFileTransferRequest

enum AppleFileTransferServiceError: LocalizedError, Equatable {
    case unavailable
    case transferAlreadyInProgress
    case notControlling
    case unsupportedItem
    case senderFailed
    case invalidSenderOutput
    case remoteRejected
    case closed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "File transfer is unavailable on this version of macOS."
        case .transferAlreadyInProgress:
            "Another file transfer is already in progress."
        case .notControlling:
            "File transfer is unavailable while observing the remote Mac."
        case .unsupportedItem:
            "Only one regular file can be transferred at a time."
        case .senderFailed:
            "The file could not be read for transfer."
        case .invalidSenderOutput:
            "The file transfer protocol returned invalid data."
        case .remoteRejected:
            "The remote Mac could not receive the file."
        case .closed:
            "The Screen Sharing session is closed."
        }
    }
}

enum AppleFileTransferState: Equatable, Sendable {
    case waitingForRemote
    case sending
    case completing
    case sent
    case failed(String)
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .sent, .failed, .cancelled: true
        case .waitingForRemote, .sending, .completing: false
        }
    }
}

struct AppleFileTransferEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let fileURL: URL
    let remoteName: String
    let startedAt: Date
    var progress: Double
    var state: AppleFileTransferState
}

@MainActor
final class AppleFileTransferHistory: ObservableObject {
    @Published private(set) var entries = [AppleFileTransferEntry]()

    var hasActiveTransfer: Bool { entries.contains { !$0.state.isTerminal } }
    var preventsNewDrop: Bool {
        entries.contains {
            switch $0.state {
            case .waitingForRemote, .sending, .completing: true
            case .sent, .failed, .cancelled: false
            }
        }
    }
    var canClear: Bool { entries.contains { $0.state.isTerminal } }

    @discardableResult
    func begin(
        identifier: UUID = UUID(),
        fileURL: URL,
        remoteName: String
    ) -> UUID {
        entries.insert(AppleFileTransferEntry(
            id: identifier,
            fileURL: fileURL,
            remoteName: remoteName,
            startedAt: Date(),
            progress: 0,
            state: .waitingForRemote
        ), at: 0)
        return identifier
    }

    func update(_ identifier: UUID, progress: Double? = nil, state: AppleFileTransferState? = nil) {
        guard let index = entries.firstIndex(where: { $0.id == identifier }) else { return }
        if let progress, progress.isFinite {
            entries[index].progress = min(1, max(entries[index].progress, progress))
        }
        if let state { entries[index].state = state }
    }

    func clearCompleted() {
        entries.removeAll { $0.state.isTerminal }
    }
}

protocol AppleFileCopySenderRunning: Sendable {
    var isAvailable: Bool { get }
    func run(
        for fileURL: URL,
        sessionID: UInt32,
        receive: @escaping @Sendable (AppleFileCopyToolOutput) async throws -> Void
    ) async throws
}

struct AppleSystemFileCopySender: AppleFileCopySenderRunning {
    static let executableURL = URL(fileURLWithPath:
        "/System/Library/PrivateFrameworks/ScreenSharing.framework/Versions/A/Resources/SSFileCopySenderFW"
    )

    let executableURL: URL

    init(executableURL: URL = Self.executableURL) {
        self.executableURL = executableURL
    }

    var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executableURL.path)
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
        let executableURL = executableURL
        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        process.executableURL = executableURL
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

actor AppleFileTransferService {
    typealias Send = @Sendable ([Data]) async throws -> Void

    private struct PendingDrop {
        let id: UUID
        let sessionID: UInt32
        let fileURL: URL
        let startedAtNanoseconds: UInt64
        let accessedSecurityScopedResource: Bool
    }

    private struct ActiveTransfer {
        let dropID: UUID
        let sessionID: UInt32
        let historyID: UUID
        let fileURL: URL
        let accessedSecurityScopedResource: Bool
        var totalBytes: UInt64?
        var transferredBytes: UInt64 = 0
        var sentDone = false
        var toolReportedFinished = false
        var senderFinished = false
        var remoteCompletion: (errorCode: UInt16, name: String)?
    }

    static let dropRequestLifetimeNanoseconds: UInt64 = 120 * 1_000_000_000

    nonisolated let history: AppleFileTransferHistory
    private let remoteName: String
    private let sender: any AppleFileCopySenderRunning
    private let send: Send
    private let uptimeNanoseconds: @Sendable () -> UInt64
    private let makeSessionID: @Sendable () -> UInt32
    private var pendingDrop: PendingDrop?
    private var activeTransfer: ActiveTransfer?
    private var transferTask: Task<Void, Never>?
    private var isControlling = true
    private var isClosed = false

    init(
        remoteName: String,
        history: AppleFileTransferHistory,
        sender: any AppleFileCopySenderRunning = AppleSystemFileCopySender(),
        uptimeNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        makeSessionID: @escaping @Sendable () -> UInt32 = {
            UInt32.random(in: 1...0x7fff_ffff)
        },
        send: @escaping Send
    ) {
        self.remoteName = remoteName
        self.history = history
        self.sender = sender
        self.uptimeNanoseconds = uptimeNanoseconds
        self.makeSessionID = makeSessionID
        self.send = send
    }

    var canAcceptDrop: Bool {
        isControlling && !isClosed && sender.isAvailable
            && activeTransfer == nil
    }

    func beginDrop(fileURL: URL) async throws -> UInt32 {
        guard canAcceptDrop else {
            if !sender.isAvailable { throw AppleFileTransferServiceError.unavailable }
            if activeTransfer != nil {
                throw AppleFileTransferServiceError.transferAlreadyInProgress
            }
            if isClosed { throw AppleFileTransferServiceError.closed }
            throw AppleFileTransferServiceError.notControlling
        }
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw AppleFileTransferServiceError.unsupportedItem
        }

        var sessionID = makeSessionID() & 0x7fff_ffff
        if sessionID == 0 { sessionID = 1 }
        let accessed = fileURL.startAccessingSecurityScopedResource()
        let dropID = UUID()
        let supersededDrop = pendingDrop
        let newDrop = PendingDrop(
            id: dropID,
            sessionID: sessionID,
            fileURL: fileURL,
            startedAtNanoseconds: uptimeNanoseconds(),
            accessedSecurityScopedResource: accessed
        )
        pendingDrop = newDrop
        if let supersededDrop {
            stopAccessing(supersededDrop)
        }
        do {
            // The ordered writer can re-enter this actor. A newer native-style drag
            // supersedes this one, so an obsolete begin must not return its SID.
            guard ownsDrop(dropID: dropID) else {
                throw CancellationError()
            }
            let message = try AppleFileTransferMessage.beginDrop(
                fileURL: fileURL,
                sessionID: sessionID
            )
            try await send([message])
            guard ownsDrop(dropID: dropID) else {
                throw CancellationError()
            }
            return sessionID
        } catch {
            failPending(dropID: dropID)
            throw error
        }
    }

    func cancelDrop(sessionID: UInt32) async {
        guard let pendingDrop, pendingDrop.sessionID == sessionID else { return }
        self.pendingDrop = nil
        do {
            let message = try AppleFileTransferMessage.cancelDrop(sessionID: sessionID)
            try await send([message])
        } catch {
            // Cancellation is best effort on the wire. The local pending state and
            // security-scoped resource must still be released after disconnects.
        }
        stopAccessing(pendingDrop)
    }

    @discardableResult
    func receive(_ message: Data) async -> Bool {
        guard let type = message.first, type == 0x1e || type == 0x22 else { return false }
        if type == 0x1e {
            guard let request = try? AppleFileTransferMessage.fileRequest(from: message) else {
                return true
            }
            await receive(request)
            return true
        }
        guard let response = try? AppleFileTransferMessage.response(from: message) else {
            return true
        }
        await receive(response)
        return true
    }

    func setControlling(_ controlling: Bool) async {
        isControlling = controlling
        if !controlling, let pendingDrop {
            await cancelDrop(sessionID: pendingDrop.sessionID)
        }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        transferTask?.cancel()
        transferTask = nil
        if let pendingDrop {
            stopAccessing(pendingDrop)
            self.pendingDrop = nil
        }
        if let activeTransfer {
            await history.update(
                activeTransfer.historyID,
                state: .failed(AppleFileTransferServiceError.closed.localizedDescription)
            )
            stopAccessing(activeTransfer)
            self.activeTransfer = nil
        }
    }

    private func receive(_ request: AppleFileTransferRequest) async {
        guard let pendingDrop, pendingDrop.sessionID == request.sessionID else { return }
        let age = uptimeNanoseconds() &- pendingDrop.startedAtNanoseconds
        guard age <= Self.dropRequestLifetimeNanoseconds else {
            failPending(dropID: pendingDrop.id)
            return
        }
        self.pendingDrop = nil
        let historyID = UUID()
        activeTransfer = ActiveTransfer(
            dropID: pendingDrop.id,
            sessionID: pendingDrop.sessionID,
            historyID: historyID,
            fileURL: pendingDrop.fileURL,
            accessedSecurityScopedResource: pendingDrop.accessedSecurityScopedResource,
            totalBytes: nil
        )
        await history.begin(
            identifier: historyID,
            fileURL: pendingDrop.fileURL,
            remoteName: remoteName
        )
        guard activeTransfer?.dropID == pendingDrop.id else {
            if isClosed {
                await history.update(
                    historyID,
                    state: .failed(AppleFileTransferServiceError.closed.localizedDescription)
                )
            }
            return
        }
        await history.update(historyID, state: .sending)
        guard activeTransfer?.dropID == pendingDrop.id else { return }
        transferTask = Task { [weak self] in
            await self?.runTransfer(request: request)
        }
    }

    private func receive(_ response: AppleFileTransferResponse) async {
        guard var activeTransfer else { return }
        switch response {
        case .completed(let sessionID, let errorCode, let name):
            guard sessionID == activeTransfer.sessionID else { return }
            activeTransfer.remoteCompletion = (errorCode, name)
            self.activeTransfer = activeTransfer
            await finishIfReady()
        case .progress(let sessionID, let fraction):
            guard sessionID == activeTransfer.sessionID, fraction.isFinite else { return }
            await history.update(activeTransfer.historyID, progress: fraction)
        }
    }

    private func runTransfer(request: AppleFileTransferRequest) async {
        do {
            let command = try AppleFileTransferMessage.startFileReceive(
                sessionID: request.sessionID,
                destinationPath: request.destinationPath
            )
            let fragments = AppleFileTransferMessage.fragments(of: command)
            try await send(fragments)
            guard let activeTransfer, activeTransfer.sessionID == request.sessionID else { return }
            try await sender.run(
                for: activeTransfer.fileURL,
                sessionID: request.sessionID
            ) { [weak self] output in
                guard let self else { throw CancellationError() }
                try Task.checkCancellation()
                try await self.senderDidOutput(output, sessionID: request.sessionID)
            }
            guard var latestTransfer = self.activeTransfer,
                  latestTransfer.sessionID == request.sessionID,
                  latestTransfer.toolReportedFinished,
                  latestTransfer.sentDone else {
                throw AppleFileTransferServiceError.senderFailed
            }
            latestTransfer.senderFinished = true
            self.activeTransfer = latestTransfer
            transferTask = nil
            await finishIfReady()
        } catch is CancellationError {
            // Session close owns the terminal history update.
        } catch {
            await failActive(error)
        }
    }

    private func senderDidOutput(
        _ output: AppleFileCopyToolOutput,
        sessionID: UInt32
    ) async throws {
        guard !isClosed, activeTransfer?.sessionID == sessionID else {
            throw CancellationError()
        }
        switch output {
        case .frame(let message):
            let frame = try AppleFileTransferMessage.senderFrame(
                from: message,
                expectedSessionID: sessionID
            )
            let fragments = AppleFileTransferMessage.fragments(of: message)
            try await send(fragments)
            await senderFrameDidSend(frame)
            if let status = frame.status, status != 0 {
                throw AppleFileTransferServiceError.senderFailed
            }
        case .itemInfo(let message):
            let frame = try AppleFileTransferMessage.senderItemInfo(
                from: message,
                expectedSessionID: sessionID
            )
            await senderFrameDidSend(frame)
        case .finished(let status):
            guard var activeTransfer,
                  activeTransfer.sessionID == sessionID,
                  !activeTransfer.toolReportedFinished else {
                throw AppleFileTransferServiceError.invalidSenderOutput
            }
            guard status == 0 else { throw AppleFileTransferServiceError.senderFailed }
            activeTransfer.toolReportedFinished = true
            self.activeTransfer = activeTransfer
        }
    }

    private func senderFrameDidSend(_ frame: AppleFileCopyFrame) async {
        guard var activeTransfer, activeTransfer.sessionID == frame.sessionID else { return }
        if let totalBytes = frame.totalBytes { activeTransfer.totalBytes = totalBytes }
        let (transferredBytes, overflow) = activeTransfer.transferredBytes.addingReportingOverflow(
            frame.transferredBytes
        )
        activeTransfer.transferredBytes = overflow ? .max : transferredBytes
        if frame.isDone { activeTransfer.sentDone = true }
        self.activeTransfer = activeTransfer
        if frame.isDone {
            await history.update(activeTransfer.historyID, progress: 1, state: .completing)
        } else if let totalBytes = activeTransfer.totalBytes, totalBytes > 0 {
            await history.update(
                activeTransfer.historyID,
                progress: Double(min(activeTransfer.transferredBytes, totalBytes)) / Double(totalBytes)
            )
        }
    }

    private func finishIfReady() async {
        guard let activeTransfer,
              activeTransfer.sentDone,
              activeTransfer.senderFinished,
              let completion = activeTransfer.remoteCompletion else { return }
        self.activeTransfer = nil
        transferTask = nil
        if completion.errorCode == 0 {
            await history.update(activeTransfer.historyID, progress: 1, state: .sent)
        } else {
            await history.update(
                activeTransfer.historyID,
                state: .failed(AppleFileTransferServiceError.remoteRejected.localizedDescription)
            )
        }
        stopAccessing(activeTransfer)
    }

    private func ownsDrop(dropID: UUID) -> Bool {
        pendingDrop?.id == dropID || activeTransfer?.dropID == dropID
    }

    private func failPending(dropID: UUID) {
        guard let pendingDrop, pendingDrop.id == dropID else { return }
        self.pendingDrop = nil
        stopAccessing(pendingDrop)
    }

    private func failActive(_ error: Error) async {
        guard let activeTransfer else { return }
        self.activeTransfer = nil
        transferTask?.cancel()
        transferTask = nil
        await history.update(
            activeTransfer.historyID,
            state: .failed(error.localizedDescription)
        )
        stopAccessing(activeTransfer)
    }

    private func stopAccessing(_ pending: PendingDrop) {
        if pending.accessedSecurityScopedResource {
            pending.fileURL.stopAccessingSecurityScopedResource()
        }
    }

    private func stopAccessing(_ active: ActiveTransfer) {
        if active.accessedSecurityScopedResource {
            active.fileURL.stopAccessingSecurityScopedResource()
        }
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
