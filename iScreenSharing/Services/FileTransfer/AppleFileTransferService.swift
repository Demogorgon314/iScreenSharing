import Foundation
import enum ScreenSharingProtocol.AppleFileCopyToolOutput
import struct ScreenSharingProtocol.AppleFileCopyReceiverFrame
import enum ScreenSharingProtocol.AppleFileTransferMessage
import enum ScreenSharingProtocol.AppleFileTransferResponse
import struct ScreenSharingProtocol.AppleRemoteFileDrag
import struct ScreenSharingProtocol.AppleFileCopyFrame
import struct ScreenSharingProtocol.AppleFileTransferRequest

enum AppleFileTransferServiceError: LocalizedError, Equatable {
    case unavailable
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
        case .notControlling:
            "File transfer is unavailable while observing the remote Mac."
        case .unsupportedItem:
            "Only files, folders, and symbolic links can be transferred."
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
    case receiving
    case paused
    case completing
    case sent
    case received
    case failed(String)
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .sent, .received, .failed, .cancelled: true
        case .waitingForRemote, .sending, .receiving, .paused, .completing: false
        }
    }
}

enum AppleFileTransferDirection: Equatable, Sendable {
    case toRemote
    case fromRemote
}

struct AppleFileTransferEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    var fileURL: URL
    let remoteName: String
    let direction: AppleFileTransferDirection
    let startedAt: Date
    var progress: Double
    var state: AppleFileTransferState
}

@MainActor
final class AppleFileTransferHistory: ObservableObject {
    @Published private(set) var entries = [AppleFileTransferEntry]()

    var hasActiveTransfer: Bool { entries.contains { !$0.state.isTerminal } }
    var canClear: Bool { entries.contains { $0.state.isTerminal } }

    @discardableResult
    func begin(
        identifier: UUID = UUID(),
        fileURL: URL,
        remoteName: String,
        direction: AppleFileTransferDirection = .toRemote
    ) -> UUID {
        entries.insert(AppleFileTransferEntry(
            id: identifier,
            fileURL: fileURL,
            remoteName: remoteName,
            direction: direction,
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

    func update(_ identifier: UUID, fileURL: URL) {
        guard let index = entries.firstIndex(where: { $0.id == identifier }) else { return }
        entries[index].fileURL = fileURL
    }

    func clearCompleted() {
        entries.removeAll { $0.state.isTerminal }
    }
}

final class AppleRemoteFileDragState: ObservableObject {
    @Published private(set) var drag: AppleRemoteFileDrag?

    @MainActor
    func receive(_ drag: AppleRemoteFileDrag) {
        self.drag = drag
    }

    @MainActor
    func clear(sessionID: UInt32? = nil) {
        guard sessionID == nil || drag?.sessionID == sessionID else { return }
        drag = nil
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

private final class AppleFileCopySessionIDGenerator: @unchecked Sendable {
    static let shared = AppleFileCopySessionIDGenerator()

    private let lock = NSLock()
    private var value: UInt32 = 0

    func next() -> UInt32 {
        lock.withLock {
            value &+= 1
            if value == 0 { value = 1 }
            return value
        }
    }
}

actor AppleFileTransferService {
    typealias Send = @Sendable ([Data]) async throws -> Void
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private struct PendingDrop {
        struct Item {
            let fileURL: URL
            let accessedSecurityScopedResource: Bool
        }

        let id: UUID
        let sessionID: UInt32
        let items: [Item]
        let startedAtNanoseconds: UInt64
    }

    private struct ActiveTransfer {
        let id: UUID
        let sessionID: UInt32
        let historyID: UUID
        let fileURL: URL
        let destinationPath: String
        let accessedSecurityScopedResource: Bool
        var hasStarted: Bool
        var totalBytes: UInt64?
        var transferredBytes: UInt64 = 0
        var sentDone = false
        var toolReportedFinished = false
        var senderFinished = false
        var isPaused = false
        var remoteCompletion: (errorCode: UInt16, name: String)?
    }

    private struct IncomingTransfer {
        let id: UUID
        let sessionID: UInt32
        let historyID: UUID
        let sourcePath: String
        let destinationURL: URL
        let accessedSecurityScopedResource: Bool
        let receiver: AppleSwiftFileCopyReceiver
        let continuation: CheckedContinuation<URL, Error>
        var hasStarted: Bool
        var isPaused: Bool
        var lastPublishedProgress: Double
    }

    private enum QueuedTransfer: Equatable {
        case outgoing(UInt32)
        case incoming(UInt32)
    }

    private struct SenderPauseWaiter {
        let transferID: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    static let dropRequestLifetimeNanoseconds: UInt64 = 120 * 1_000_000_000
    static let remoteDragLifetime: Duration = .seconds(120)
    static let maximumConcurrentTransfers = 4

    nonisolated let history: AppleFileTransferHistory
    nonisolated let remoteDrag = AppleRemoteFileDragState()
    private let remoteName: String
    private let sender: any AppleFileCopySenderRunning
    private let send: Send
    private let uptimeNanoseconds: @Sendable () -> UInt64
    private let makeSessionID: @Sendable () -> UInt32
    private let makeFileCopySessionID: @Sendable () -> UInt32
    private let sleep: Sleep
    private var pendingDrop: PendingDrop?
    private var activeTransfers = [UInt32: ActiveTransfer]()
    private var transferTasks = [UInt32: Task<Void, Never>]()
    private var senderPauseWaiters = [UInt32: [SenderPauseWaiter]]()
    private var incomingTransfers = [UInt32: IncomingTransfer]()
    private var queuedTransfers = [QueuedTransfer]()
    private var incomingMessageBuffer = Data()
    private var incomingMessageLength: Int?
    private var remoteDragSessionID: UInt32?
    private var remoteDragExpirationTask: Task<Void, Never>?
    private var isControlling = true
    private var isClosed = false

    init(
        remoteName: String,
        history: AppleFileTransferHistory,
        sender: any AppleFileCopySenderRunning = AppleSwiftFileCopySender(),
        uptimeNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        makeSessionID: @escaping @Sendable () -> UInt32 = {
            UInt32.random(in: 1...0x7fff_ffff)
        },
        makeFileCopySessionID: @escaping @Sendable () -> UInt32 = {
            AppleFileCopySessionIDGenerator.shared.next()
        },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        send: @escaping Send
    ) {
        self.remoteName = remoteName
        self.history = history
        self.sender = sender
        self.uptimeNanoseconds = uptimeNanoseconds
        self.makeSessionID = makeSessionID
        self.makeFileCopySessionID = makeFileCopySessionID
        self.sleep = sleep
        self.send = send
    }

    var canAcceptDrop: Bool {
        isControlling && !isClosed && sender.isAvailable
    }

    func beginDrop(fileURL: URL) async throws -> UInt32 {
        try await beginDrop(fileURLs: [fileURL])
    }

    func beginDrop(fileURLs: [URL]) async throws -> UInt32 {
        guard canAcceptDrop else {
            if !sender.isAvailable { throw AppleFileTransferServiceError.unavailable }
            if isClosed { throw AppleFileTransferServiceError.closed }
            throw AppleFileTransferServiceError.notControlling
        }
        guard !fileURLs.isEmpty else { throw AppleFileTransferServiceError.unsupportedItem }
        var items = [PendingDrop.Item]()
        do {
            for fileURL in fileURLs {
                let values = try fileURL.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ])
                guard values.isRegularFile == true
                        || values.isDirectory == true
                        || values.isSymbolicLink == true else {
                    throw AppleFileTransferServiceError.unsupportedItem
                }
                items.append(PendingDrop.Item(
                    fileURL: fileURL,
                    accessedSecurityScopedResource: fileURL.startAccessingSecurityScopedResource()
                ))
            }
        } catch {
            items.forEach(Self.stopAccessing)
            throw error
        }

        var sessionID = makeSessionID() & 0x7fff_ffff
        if sessionID == 0 { sessionID = 1 }
        let dropID = UUID()
        let supersededDrop = pendingDrop
        let newDrop = PendingDrop(
            id: dropID,
            sessionID: sessionID,
            items: items,
            startedAtNanoseconds: uptimeNanoseconds()
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
                fileURLs: fileURLs,
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
    func receive(_ fragment: Data) async -> Bool {
        guard !fragment.isEmpty else { return false }
        if isClosed {
            return fragment.first == 0x1e || fragment.first == 0x20 || fragment.first == 0x22
        }
        if incomingMessageBuffer.isEmpty {
            guard let type = fragment.first,
                  type == 0x1e || type == 0x20 || type == 0x22 else { return false }
            incomingMessageBuffer = fragment
            do {
                incomingMessageLength = try AppleFileTransferMessage
                    .expectedStreamMessageLength(from: incomingMessageBuffer)
            } catch {
                let malformedMessage = incomingMessageBuffer
                resetIncomingMessage()
                await rejectMalformedMessage(malformedMessage)
                return true
            }
        } else {
            incomingMessageBuffer.append(fragment)
        }
        if incomingMessageLength == nil {
            do {
                incomingMessageLength = try AppleFileTransferMessage
                    .expectedStreamMessageLength(from: incomingMessageBuffer)
            } catch {
                let malformedMessage = incomingMessageBuffer
                resetIncomingMessage()
                await rejectMalformedMessage(malformedMessage)
                return true
            }
        }
        guard let expectedLength = incomingMessageLength else { return true }
        guard incomingMessageBuffer.count <= expectedLength else {
            let malformedMessage = incomingMessageBuffer
            resetIncomingMessage()
            await rejectMalformedMessage(malformedMessage)
            return true
        }
        guard incomingMessageBuffer.count == expectedLength else { return true }
        let message = incomingMessageBuffer
        resetIncomingMessage()
        await receiveCompleteMessage(message)
        return true
    }

    func receiveRemoteFile(sourcePath: String, destinationURL: URL) async throws -> URL {
        guard !isClosed else { throw AppleFileTransferServiceError.closed }
        let destinationDirectory = destinationURL.deletingLastPathComponent()
        let accessed = destinationDirectory.startAccessingSecurityScopedResource()
        let receiver: AppleSwiftFileCopyReceiver
        do {
            receiver = try AppleSwiftFileCopyReceiver(
                destinationDirectory: destinationDirectory,
                requestedName: destinationURL.lastPathComponent
            )
        } catch {
            if accessed { destinationDirectory.stopAccessingSecurityScopedResource() }
            throw error
        }
        let sessionID = allocateFileCopySessionID()
        let transferID = UUID()
        let historyID = await history.begin(
            fileURL: destinationURL,
            remoteName: remoteName,
            direction: .fromRemote
        )
        if isClosed {
            await history.update(
                historyID,
                state: .failed(AppleFileTransferServiceError.closed.localizedDescription)
            )
            if accessed { destinationDirectory.stopAccessingSecurityScopedResource() }
            throw AppleFileTransferServiceError.closed
        }
        if Task.isCancelled {
            await history.update(historyID, state: .cancelled)
            if accessed { destinationDirectory.stopAccessingSecurityScopedResource() }
            throw CancellationError()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                incomingTransfers[sessionID] = IncomingTransfer(
                    id: transferID,
                    sessionID: sessionID,
                    historyID: historyID,
                    sourcePath: sourcePath,
                    destinationURL: destinationURL,
                    accessedSecurityScopedResource: accessed,
                    receiver: receiver,
                    continuation: continuation,
                    hasStarted: false,
                    isPaused: false,
                    lastPublishedProgress: 0
                )
                queuedTransfers.append(.incoming(sessionID))
                Task { [weak self] in await self?.startQueuedTransfers() }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelIncomingTransfer(
                    sessionID: sessionID,
                    expectedID: transferID
                )
            }
        }
    }

    func setControlling(_ controlling: Bool) async {
        isControlling = controlling
        if !controlling, let pendingDrop {
            await cancelDrop(sessionID: pendingDrop.sessionID)
        }
    }

    func cancelTransfer(historyID: UUID) async {
        if let transfer = incomingTransfers.values.first(where: { $0.historyID == historyID }) {
            await cancelIncomingTransfer(
                sessionID: transfer.sessionID,
                expectedID: transfer.id
            )
            return
        }
        guard let transfer = activeTransfers.values.first(where: {
            $0.historyID == historyID
        }) else { return }
        await cancelActiveTransfer(
            sessionID: transfer.sessionID,
            expectedID: transfer.id
        )
    }

    func setTransferPaused(historyID: UUID, paused: Bool) async {
        if let transfer = incomingTransfers.values.first(where: {
            $0.historyID == historyID
        }) {
            await setIncomingTransfer(
                transfer,
                paused: paused
            )
            return
        }
        guard let transfer = activeTransfers.values.first(where: {
            $0.historyID == historyID
        }) else { return }
        await setOutgoingTransfer(
            transfer,
            paused: paused
        )
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        let outgoingTasks = transferTasks.values
        transferTasks.removeAll()
        outgoingTasks.forEach { $0.cancel() }
        if let pendingDrop {
            stopAccessing(pendingDrop)
            self.pendingDrop = nil
        }
        let outgoing = activeTransfers.values
        activeTransfers.removeAll()
        for transfer in outgoing {
            resumeSenderPauseWaiters(
                sessionID: transfer.sessionID,
                expectedID: transfer.id
            )
            await history.update(
                transfer.historyID,
                state: .failed(AppleFileTransferServiceError.closed.localizedDescription)
            )
            stopAccessing(transfer)
        }
        let incoming = incomingTransfers.values
        incomingTransfers.removeAll()
        queuedTransfers.removeAll()
        resetIncomingMessage()
        await clearRemoteDrag()
        for transfer in incoming {
            await history.update(
                transfer.historyID,
                state: .failed(AppleFileTransferServiceError.closed.localizedDescription)
            )
            stopAccessing(transfer)
            transfer.continuation.resume(throwing: AppleFileTransferServiceError.closed)
        }
    }

    private func receiveCompleteMessage(_ message: Data) async {
        switch message.first {
        case 0x1e:
            guard let request = try? AppleFileTransferMessage.fileRequest(from: message) else {
                await rejectMalformedMessage(message)
                return
            }
            await receive(request)
        case 0x20:
            let sessionID = Self.sessionID(fromRemoteDragMessage: message)
            do {
                if let drag = try AppleFileTransferMessage.remoteDrag(from: message) {
                    await remoteDrag.receive(drag)
                    scheduleRemoteDragExpiration(sessionID: drag.sessionID)
                } else if sessionID != 0 {
                    // Native treats the type-32 SID as informational on this path.
                    await clearRemoteDrag()
                }
            } catch {
                if sessionID != 0 { await clearRemoteDrag() }
            }
        case 0x22:
            if let sessionID = Self.sessionID(fromFileCopyMessage: message),
               incomingTransfers[sessionID] != nil {
                do {
                    try await receiveIncoming(
                        AppleFileTransferMessage.receiverFrame(from: message)
                    )
                } catch {
                    let remoteAlreadyEnded: Bool
                    if let receiverError = error as? AppleSwiftFileCopyReceiverError,
                       case .remoteFailed = receiverError {
                        remoteAlreadyEnded = true
                    } else {
                        remoteAlreadyEnded = false
                    }
                    await failIncomingTransfer(
                        sessionID: sessionID,
                        error: error,
                        sendsStop: !remoteAlreadyEnded
                    )
                }
                return
            }
            guard let response = try? AppleFileTransferMessage.response(from: message) else {
                await rejectMalformedMessage(message)
                return
            }
            await receive(response)
        default:
            break
        }
    }

    private func receiveIncoming(_ frame: AppleFileCopyReceiverFrame) async throws {
        guard var transfer = incomingTransfers[frame.sessionID], transfer.hasStarted else {
            throw AppleSwiftFileCopyReceiverError.invalidSequence
        }
        let update = try transfer.receiver.receive(frame.payload)
        if case .summary = frame.payload {
            await history.update(
                transfer.historyID,
                progress: 0,
                state: transfer.isPaused ? .paused : .receiving
            )
            guard ownsIncomingTransfer(transfer) else { return }
        }
        if let progress = update.progress,
           progress == 1 || progress - transfer.lastPublishedProgress >= 0.025 {
            transfer.lastPublishedProgress = progress
            incomingTransfers[frame.sessionID] = transfer
            await history.update(transfer.historyID, progress: progress)
            guard ownsIncomingTransfer(transfer) else { return }
        }
        guard let completedURL = update.completedURL else { return }
        guard incomingTransfers.removeValue(forKey: frame.sessionID)?.id == transfer.id else {
            return
        }
        stopAccessing(transfer)
        transfer.continuation.resume(returning: completedURL)
        await history.update(transfer.historyID, fileURL: completedURL)
        await history.update(transfer.historyID, progress: 1, state: .received)
        await startQueuedTransfers()
    }

    private func startQueuedTransfers() async {
        while activeFileCopyCount < Self.maximumConcurrentTransfers,
              !queuedTransfers.isEmpty {
            switch queuedTransfers.removeFirst() {
            case .outgoing(let sessionID):
                guard var transfer = activeTransfers[sessionID],
                      !transfer.hasStarted else { continue }
                transfer.hasStarted = true
                activeTransfers[sessionID] = transfer
                await history.update(transfer.historyID, state: .sending)
                do {
                    let command = try AppleFileTransferMessage.startFileReceive(
                        sessionID: sessionID,
                        destinationPath: transfer.destinationPath
                    )
                    try await send(AppleFileTransferMessage.fragments(of: command))
                    guard !isClosed,
                          activeTransfers[sessionID]?.id == transfer.id,
                          activeTransfers[sessionID]?.hasStarted == true else { continue }
                    transferTasks[sessionID] = Task { [weak self] in
                        await self?.runTransfer(
                            sessionID: sessionID,
                            transferID: transfer.id
                        )
                    }
                } catch {
                    await failActive(
                        sessionID: sessionID,
                        error: error,
                        expectedID: transfer.id,
                        startsNextTransfer: false
                    )
                }
            case .incoming(let sessionID):
                guard var transfer = incomingTransfers[sessionID],
                      !transfer.hasStarted else { continue }
                do {
                    let message = try AppleFileTransferMessage.startFileSend(
                        sessionID: sessionID,
                        sourcePath: transfer.sourcePath
                    )
                    transfer.hasStarted = true
                    incomingTransfers[sessionID] = transfer
                    try await send(AppleFileTransferMessage.fragments(of: message))
                    guard !isClosed, ownsIncomingTransfer(transfer) else { continue }
                    await history.update(transfer.historyID, state: .receiving)
                } catch {
                    await failIncomingTransfer(
                        sessionID: sessionID,
                        error: error,
                        sendsStop: false,
                        startsNextTransfer: false
                    )
                }
            }
        }
    }

    private func cancelIncomingTransfer(sessionID: UInt32, expectedID: UUID) async {
        guard let transfer = incomingTransfers[sessionID], transfer.id == expectedID else { return }
        incomingTransfers.removeValue(forKey: sessionID)
        queuedTransfers.removeAll { $0 == .incoming(sessionID) }
        if transfer.hasStarted,
           let stop = try? AppleFileTransferMessage.control(sessionID: sessionID, action: .stop) {
            try? await send([stop])
        }
        await history.update(transfer.historyID, state: .cancelled)
        stopAccessing(transfer)
        transfer.continuation.resume(throwing: CancellationError())
        await startQueuedTransfers()
    }

    private func setIncomingTransfer(
        _ transfer: IncomingTransfer,
        paused: Bool
    ) async {
        guard transfer.hasStarted, transfer.isPaused != paused,
              let message = try? AppleFileTransferMessage.control(
                  sessionID: transfer.sessionID,
                  action: paused ? .pause : .resume
              ) else { return }
        do {
            try await send([message])
        } catch {
            return
        }
        guard var current = incomingTransfers[transfer.sessionID],
              current.id == transfer.id else { return }
        current.isPaused = paused
        incomingTransfers[transfer.sessionID] = current
        await history.update(
            current.historyID,
            state: paused ? .paused : .receiving
        )
    }

    private func setOutgoingTransfer(
        _ transfer: ActiveTransfer,
        paused: Bool
    ) async {
        guard transfer.hasStarted, !transfer.sentDone,
              transfer.isPaused != paused,
              let message = try? AppleFileTransferMessage.control(
                  sessionID: transfer.sessionID,
                  action: paused ? .pause : .resume
              ) else { return }

        if paused {
            guard var current = activeTransfers[transfer.sessionID],
                  current.id == transfer.id,
                  !current.sentDone else { return }
            // Native pauses the local helper listener before writing cmd3.
            // Holding this callback creates the same bounded producer
            // backpressure through AppleFileCopyOutputPipe.
            current.isPaused = true
            activeTransfers[transfer.sessionID] = current
        }
        do {
            try await send([message])
        } catch {
            if paused {
                await failActive(
                    sessionID: transfer.sessionID,
                    error: error,
                    expectedID: transfer.id
                )
            }
            return
        }
        guard var current = activeTransfers[transfer.sessionID],
              current.id == transfer.id,
              !current.sentDone else { return }
        current.isPaused = paused
        activeTransfers[transfer.sessionID] = current
        if !paused {
            resumeSenderPauseWaiters(
                sessionID: transfer.sessionID,
                expectedID: transfer.id
            )
        }
        await history.update(
            current.historyID,
            state: paused ? .paused : .sending
        )
    }

    private func cancelActiveTransfer(sessionID: UInt32, expectedID: UUID) async {
        guard let transfer = activeTransfers[sessionID], transfer.id == expectedID else { return }
        activeTransfers.removeValue(forKey: sessionID)
        queuedTransfers.removeAll { $0 == .outgoing(sessionID) }
        transferTasks.removeValue(forKey: sessionID)?.cancel()
        resumeSenderPauseWaiters(sessionID: sessionID, expectedID: expectedID)
        if transfer.hasStarted,
           let stop = try? AppleFileTransferMessage.control(
               sessionID: sessionID,
               action: .stop
           ) {
            try? await send([stop])
        }
        await history.update(transfer.historyID, state: .cancelled)
        stopAccessing(transfer)
        await startQueuedTransfers()
    }

    private func failIncomingTransfer(
        sessionID: UInt32,
        error: Error,
        sendsStop: Bool,
        startsNextTransfer: Bool = true
    ) async {
        guard let transfer = incomingTransfers.removeValue(forKey: sessionID) else { return }
        queuedTransfers.removeAll { $0 == .incoming(sessionID) }
        if sendsStop, transfer.hasStarted,
           let stop = try? AppleFileTransferMessage.control(sessionID: sessionID, action: .stop) {
            try? await send([stop])
        }
        await history.update(transfer.historyID, state: .failed(error.localizedDescription))
        stopAccessing(transfer)
        transfer.continuation.resume(throwing: error)
        if startsNextTransfer { await startQueuedTransfers() }
    }

    private var activeFileCopyCount: Int {
        incomingTransfers.values.count { $0.hasStarted }
            + activeTransfers.values.count { $0.hasStarted }
    }

    private func ownsIncomingTransfer(_ transfer: IncomingTransfer) -> Bool {
        incomingTransfers[transfer.sessionID]?.id == transfer.id
    }

    private func allocateFileCopySessionID() -> UInt32 {
        var sessionID = makeFileCopySessionID()
        if sessionID == 0 { sessionID = 1 }
        while incomingTransfers[sessionID] != nil || activeTransfers[sessionID] != nil {
            sessionID &+= 1
            if sessionID == 0 { sessionID = 1 }
        }
        return sessionID
    }

    private func resetIncomingMessage() {
        incomingMessageBuffer.removeAll(keepingCapacity: false)
        incomingMessageLength = nil
    }

    private func rejectMalformedMessage(_ message: Data) async {
        switch message.first {
        case 0x1e:
            guard message.count >= 8 else { return }
            let sessionID = UInt32(message[4]) << 24 | UInt32(message[5]) << 16
                | UInt32(message[6]) << 8 | UInt32(message[7])
            if pendingDrop?.sessionID == sessionID, let dropID = pendingDrop?.id {
                failPending(dropID: dropID)
            }
        case 0x20:
            await clearRemoteDrag()
        case 0x22:
            guard let sessionID = Self.sessionID(fromFileCopyMessage: message) else { return }
            if incomingTransfers[sessionID] != nil {
                await failIncomingTransfer(
                    sessionID: sessionID,
                    error: AppleFileTransferServiceError.invalidSenderOutput,
                    sendsStop: true
                )
            } else if activeTransfers[sessionID] != nil {
                await failActive(
                    sessionID: sessionID,
                    error: AppleFileTransferServiceError.invalidSenderOutput
                )
            }
        default:
            break
        }
    }

    private static func sessionID(fromRemoteDragMessage message: Data) -> UInt32 {
        guard message.count >= 8 else { return 0 }
        return UInt32(message[4]) << 24 | UInt32(message[5]) << 16
            | UInt32(message[6]) << 8 | UInt32(message[7])
    }

    func clearRemoteDrag() async {
        remoteDragExpirationTask?.cancel()
        remoteDragExpirationTask = nil
        remoteDragSessionID = nil
        await remoteDrag.clear()
    }

    private func scheduleRemoteDragExpiration(sessionID: UInt32) {
        remoteDragExpirationTask?.cancel()
        remoteDragSessionID = sessionID
        let sleep = sleep
        remoteDragExpirationTask = Task { [weak self] in
            do {
                try await sleep(Self.remoteDragLifetime)
            } catch {
                return
            }
            await self?.expireRemoteDrag(sessionID: sessionID)
        }
    }

    private func expireRemoteDrag(sessionID: UInt32) async {
        guard remoteDragSessionID == sessionID else { return }
        remoteDragExpirationTask = nil
        remoteDragSessionID = nil
        await remoteDrag.clear()
    }

    private static func sessionID(fromFileCopyMessage message: Data) -> UInt32? {
        guard message.count >= 14, message[0] == 0x22 else { return nil }
        return UInt32(message[10]) << 24 | UInt32(message[11]) << 16
            | UInt32(message[12]) << 8 | UInt32(message[13])
    }

    private func receive(_ request: AppleFileTransferRequest) async {
        guard let pendingDrop, pendingDrop.sessionID == request.sessionID else { return }
        let age = uptimeNanoseconds() &- pendingDrop.startedAtNanoseconds
        guard age <= Self.dropRequestLifetimeNanoseconds else {
            failPending(dropID: pendingDrop.id)
            return
        }
        self.pendingDrop = nil
        for item in pendingDrop.items {
            guard !isClosed else {
                Self.stopAccessing(item)
                continue
            }
            let historyID = UUID()
            let transferID = UUID()
            let sessionID = allocateFileCopySessionID()
            activeTransfers[sessionID] = ActiveTransfer(
                id: transferID,
                sessionID: sessionID,
                historyID: historyID,
                fileURL: item.fileURL,
                destinationPath: request.destinationPath,
                accessedSecurityScopedResource: item.accessedSecurityScopedResource,
                hasStarted: false,
                totalBytes: nil
            )
            await history.begin(
                identifier: historyID,
                fileURL: item.fileURL,
                remoteName: remoteName
            )
            guard !isClosed, activeTransfers[sessionID]?.id == transferID else { continue }
            queuedTransfers.append(.outgoing(sessionID))
        }
        await startQueuedTransfers()
    }

    private func receive(_ response: AppleFileTransferResponse) async {
        switch response {
        case .completed(let sessionID, let errorCode, let name):
            guard var transfer = activeTransfers[sessionID] else { return }
            transfer.remoteCompletion = (errorCode, name)
            activeTransfers[sessionID] = transfer
            await finishIfReady(sessionID: sessionID)
        case .progress(let sessionID, let fraction):
            guard let transfer = activeTransfers[sessionID], fraction.isFinite else { return }
            await history.update(transfer.historyID, progress: fraction)
        }
    }

    private func runTransfer(
        sessionID: UInt32,
        transferID: UUID
    ) async {
        do {
            guard let activeTransfer = activeTransfers[sessionID],
                  activeTransfer.id == transferID else { return }
            try await sender.run(
                for: activeTransfer.fileURL,
                sessionID: sessionID
            ) { [weak self] output in
                guard let self else { throw CancellationError() }
                try Task.checkCancellation()
                try await self.senderDidOutput(
                    output,
                    sessionID: sessionID,
                    expectedID: transferID
                )
            }
            guard var latestTransfer = activeTransfers[sessionID],
                  latestTransfer.id == transferID,
                  latestTransfer.toolReportedFinished,
                  latestTransfer.sentDone else {
                throw AppleFileTransferServiceError.senderFailed
            }
            latestTransfer.senderFinished = true
            activeTransfers[sessionID] = latestTransfer
            transferTasks.removeValue(forKey: sessionID)
            await finishIfReady(sessionID: sessionID, expectedID: transferID)
        } catch is CancellationError {
            // Session close owns the terminal history update.
        } catch {
            await failActive(
                sessionID: sessionID,
                error: error,
                expectedID: transferID
            )
        }
    }

    private func senderDidOutput(
        _ output: AppleFileCopyToolOutput,
        sessionID: UInt32,
        expectedID: UUID
    ) async throws {
        try await waitForOutgoingTransferToResume(
            sessionID: sessionID,
            expectedID: expectedID
        )
        guard !isClosed, activeTransfers[sessionID]?.id == expectedID else {
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
            await senderFrameDidSend(frame, expectedID: expectedID)
            if let status = frame.status, status != 0 {
                throw AppleFileTransferServiceError.senderFailed
            }
        case .itemInfo(let message):
            let frame = try AppleFileTransferMessage.senderItemInfo(
                from: message,
                expectedSessionID: sessionID
            )
            await senderFrameDidSend(frame, expectedID: expectedID)
        case .finished(let status):
            guard var activeTransfer = activeTransfers[sessionID],
                  activeTransfer.id == expectedID,
                  !activeTransfer.toolReportedFinished else {
                throw AppleFileTransferServiceError.invalidSenderOutput
            }
            guard status == 0 else { throw AppleFileTransferServiceError.senderFailed }
            activeTransfer.toolReportedFinished = true
            activeTransfers[sessionID] = activeTransfer
        }
    }

    private func senderFrameDidSend(
        _ frame: AppleFileCopyFrame,
        expectedID: UUID
    ) async {
        guard var activeTransfer = activeTransfers[frame.sessionID],
              activeTransfer.id == expectedID else { return }
        if let totalBytes = frame.totalBytes { activeTransfer.totalBytes = totalBytes }
        let (transferredBytes, overflow) = activeTransfer.transferredBytes.addingReportingOverflow(
            frame.transferredBytes
        )
        activeTransfer.transferredBytes = overflow ? .max : transferredBytes
        if frame.isDone { activeTransfer.sentDone = true }
        activeTransfers[frame.sessionID] = activeTransfer
        if frame.isDone {
            await history.update(activeTransfer.historyID, progress: 1, state: .completing)
        } else if let totalBytes = activeTransfer.totalBytes, totalBytes > 0 {
            await history.update(
                activeTransfer.historyID,
                progress: Double(min(activeTransfer.transferredBytes, totalBytes)) / Double(totalBytes)
            )
        }
    }

    private func finishIfReady(
        sessionID: UInt32,
        expectedID: UUID? = nil
    ) async {
        guard let activeTransfer = activeTransfers[sessionID],
              expectedID == nil || activeTransfer.id == expectedID,
              activeTransfer.sentDone,
              activeTransfer.senderFinished,
              let completion = activeTransfer.remoteCompletion else { return }
        activeTransfers.removeValue(forKey: sessionID)
        transferTasks.removeValue(forKey: sessionID)
        resumeSenderPauseWaiters(
            sessionID: sessionID,
            expectedID: activeTransfer.id
        )
        if completion.errorCode == 0 {
            await history.update(activeTransfer.historyID, progress: 1, state: .sent)
        } else {
            await history.update(
                activeTransfer.historyID,
                state: .failed(AppleFileTransferServiceError.remoteRejected.localizedDescription)
            )
        }
        stopAccessing(activeTransfer)
        await startQueuedTransfers()
    }

    private func ownsDrop(dropID: UUID) -> Bool {
        pendingDrop?.id == dropID
    }

    private func failPending(dropID: UUID) {
        guard let pendingDrop, pendingDrop.id == dropID else { return }
        self.pendingDrop = nil
        stopAccessing(pendingDrop)
    }

    private func failActive(
        sessionID: UInt32,
        error: Error,
        expectedID: UUID? = nil,
        startsNextTransfer: Bool = true
    ) async {
        guard let activeTransfer = activeTransfers[sessionID],
              expectedID == nil || activeTransfer.id == expectedID else { return }
        activeTransfers.removeValue(forKey: sessionID)
        transferTasks.removeValue(forKey: sessionID)?.cancel()
        resumeSenderPauseWaiters(
            sessionID: sessionID,
            expectedID: activeTransfer.id
        )
        queuedTransfers.removeAll { $0 == .outgoing(sessionID) }
        await history.update(
            activeTransfer.historyID,
            state: .failed(error.localizedDescription)
        )
        stopAccessing(activeTransfer)
        if startsNextTransfer { await startQueuedTransfers() }
    }

    private func waitForOutgoingTransferToResume(
        sessionID: UInt32,
        expectedID: UUID
    ) async throws {
        try Task.checkCancellation()
        while true {
            guard !isClosed,
                  let transfer = activeTransfers[sessionID],
                  transfer.id == expectedID else {
                throw CancellationError()
            }
            guard transfer.isPaused else { return }
            await withCheckedContinuation { continuation in
                guard !isClosed,
                      let current = activeTransfers[sessionID],
                      current.id == expectedID,
                      current.isPaused else {
                    continuation.resume()
                    return
                }
                senderPauseWaiters[sessionID, default: []].append(
                    SenderPauseWaiter(
                        transferID: expectedID,
                        continuation: continuation
                    )
                )
            }
            try Task.checkCancellation()
        }
    }

    private func resumeSenderPauseWaiters(
        sessionID: UInt32,
        expectedID: UUID
    ) {
        guard let waiters = senderPauseWaiters[sessionID] else { return }
        var retained = [SenderPauseWaiter]()
        for waiter in waiters {
            if waiter.transferID == expectedID {
                waiter.continuation.resume()
            } else {
                retained.append(waiter)
            }
        }
        if retained.isEmpty {
            senderPauseWaiters.removeValue(forKey: sessionID)
        } else {
            senderPauseWaiters[sessionID] = retained
        }
    }

    private func stopAccessing(_ pending: PendingDrop) {
        pending.items.forEach(Self.stopAccessing)
    }

    private static func stopAccessing(_ item: PendingDrop.Item) {
        if item.accessedSecurityScopedResource {
            item.fileURL.stopAccessingSecurityScopedResource()
        }
    }

    private func stopAccessing(_ active: ActiveTransfer) {
        if active.accessedSecurityScopedResource {
            active.fileURL.stopAccessingSecurityScopedResource()
        }
    }

    private func stopAccessing(_ incoming: IncomingTransfer) {
        if incoming.accessedSecurityScopedResource {
            incoming.destinationURL.deletingLastPathComponent()
                .stopAccessingSecurityScopedResource()
        }
    }
}
