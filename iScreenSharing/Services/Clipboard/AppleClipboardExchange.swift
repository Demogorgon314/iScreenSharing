import Foundation
import enum ScreenSharingProtocol.AppleClipboardMessage
import struct ScreenSharingProtocol.AppleClipboardArchive
import struct ScreenSharingProtocol.AppleClipboardReassembler
import struct ScreenSharingProtocol.AppleClipboardRequest

actor AppleClipboardExchange {
    typealias SendRequest = @Sendable (_ promises: Bool, _ sessionID: UInt32) async throws -> Void
    typealias SendArchive = @Sendable (
        _ archive: AppleClipboardArchive,
        _ promises: Bool,
        _ sessionID: UInt32
    ) async throws -> Void

    private enum RequestState: Equatable {
        case idle
        case awaitingAutomaticPromises(sessionID: UInt32, lease: UInt64)
        case awaitingAutomaticData(lease: UInt64)
        case awaitingManualData(sessionID: UInt32)
    }

    private let clipboard: any AppleClipboardReceiving
    private let makeSessionID: @Sendable () -> UInt32
    private let uptimeNanoseconds: @Sendable () -> UInt64
    private let requestLifetimeNanoseconds: UInt64
    private let sendRequest: SendRequest
    private let sendArchive: SendArchive
    private var reassembler = AppleClipboardReassembler()
    private var requestState = RequestState.idle
    private var requestDeadlineNanoseconds: UInt64?

    init(
        clipboard: any AppleClipboardReceiving,
        makeSessionID: @escaping @Sendable () -> UInt32 = {
            UInt32.random(in: 1...0x7fff_ffff)
        },
        uptimeNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        requestLifetimeNanoseconds: UInt64 = 120_000_000_000,
        sendRequest: @escaping SendRequest,
        sendArchive: @escaping SendArchive
    ) {
        self.clipboard = clipboard
        self.makeSessionID = makeSessionID
        self.uptimeNanoseconds = uptimeNanoseconds
        self.requestLifetimeNanoseconds = requestLifetimeNanoseconds
        self.sendRequest = sendRequest
        self.sendArchive = sendArchive
    }

    func requestRemoteClipboard() async throws {
        let sessionID = nextSessionID()
        beginRequest(.awaitingManualData(sessionID: sessionID))
        do {
            try await sendRequest(false, sessionID)
        } catch {
            if requestState == .awaitingManualData(sessionID: sessionID) {
                resetRequest()
            }
            throw error
        }
    }

    func receive(_ message: Data) async -> Bool {
        guard !message.isEmpty else { return false }
        expireRequestIfNeeded()
        if reassembler.isInProgress || message[0] == 0x1f {
            await receiveClipboardFragment(message)
            return true
        }
        if let request = AppleClipboardMessage.request(from: message) {
            await respondToRemoteRequest(request)
            return true
        }
        guard message[0] == 0x14, message.count >= 8,
              let subtype = try? message.uint16BE(at: 6) else { return false }
        switch subtype {
        case 2:
            await remotePasteboardDidChange()
            return true
        case 3:
            await remoteNeedsLocalPasteboardData()
            return true
        default:
            return false
        }
    }

    /// Claims an unfinished message's records before the control reader treats
    /// their arbitrary payload bytes as a new message type.
    func receiveContinuation(_ message: Data) async -> Bool {
        guard reassembler.isInProgress else { return false }
        return await receive(message)
    }

    private func receiveClipboardFragment(_ fragment: Data) async {
        do {
            guard let complete = try reassembler.process(fragment) else { return }
            let envelope = try AppleClipboardMessage.envelope(from: complete)
            switch requestState {
            case .awaitingAutomaticPromises(let sessionID, let lease)
                where envelope.sessionID == sessionID && envelope.containsPromises:
                guard await clipboard.isSynchronizationLeaseValid(lease) else {
                    resetRequest()
                    return
                }
                requestState = .awaitingAutomaticData(lease: lease)
                do {
                    // Native installs an NSPasteboard promise and requests its data
                    // lazily. Until that provider exists here, eagerly requesting the
                    // same full payload must still use the native automatic ID zero.
                    try await sendRequest(false, 0)
                } catch {
                    resetRequest()
                }
            case .awaitingAutomaticData(let lease)
                where envelope.sessionID == 0 && !envelope.containsPromises:
                _ = await clipboard.receiveIfEligible(envelope.archive, lease: lease)
                resetRequest()
            case .awaitingManualData(let sessionID)
                where envelope.sessionID == sessionID && !envelope.containsPromises:
                await clipboard.receive(envelope.archive)
                resetRequest()
            default:
                return
            }
        } catch {
            reassembler = AppleClipboardReassembler()
            resetRequest()
        }
    }

    private func remotePasteboardDidChange() async {
        await clipboard.remotePasteboardDidChange()
        guard requestState == .idle else { return }
        guard let lease = await clipboard.synchronizationLease() else { return }
        let sessionID = nextSessionID()
        beginRequest(.awaitingAutomaticPromises(sessionID: sessionID, lease: lease))
        do {
            try await sendRequest(true, sessionID)
        } catch {
            resetRequest()
        }
    }

    private func remoteNeedsLocalPasteboardData() async {
        guard let archive = await clipboard.archiveForRemoteRequest() else { return }
        do {
            try await sendArchive(archive, false, 0)
            await clipboard.remoteRequestDidFinish()
        } catch {
            // Keep the outstanding-promise state so a later server request can retry.
        }
    }

    private func respondToRemoteRequest(_ request: AppleClipboardRequest) async {
        guard let archive = await clipboard.archiveForRemoteRequest() else { return }
        do {
            try await sendArchive(archive, request.requestsPromises, request.sessionID)
            if !request.requestsPromises {
                await clipboard.remoteRequestDidFinish()
            }
        } catch {
            // The ordered writer owns transport failure and session shutdown.
        }
    }

    private func nextSessionID() -> UInt32 {
        let candidate = makeSessionID() & 0x7fff_ffff
        return candidate == 0 ? 1 : candidate
    }

    private func beginRequest(_ state: RequestState) {
        // Request replacement does not change the boundary of an incoming
        // message. Finish consuming it, then reject its obsolete session ID.
        requestState = state
        requestDeadlineNanoseconds = uptimeNanoseconds() &+ requestLifetimeNanoseconds
    }

    private func resetRequest() {
        requestState = .idle
        requestDeadlineNanoseconds = nil
    }

    private func expireRequestIfNeeded() {
        guard let deadline = requestDeadlineNanoseconds,
              uptimeNanoseconds() >= deadline else { return }
        resetRequest()
    }
}
