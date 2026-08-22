import Foundation

final class AppleVideoFeedbackController: @unchecked Sendable {
    private static let minimumKeyFrameInterval: TimeInterval = 1

    private let lock = NSLock()
    private let sendLock = NSLock()
    private let sender: AppleMediaControlSending
    private let encryptor: AppleSRTCPEncryptor
    private let synchronizationSource: UInt32
    private let now: () -> TimeInterval
    private var feedbackSequence: UInt8 = 0
    private var lastKeyFrameRequest = [UInt32: TimeInterval]()
    private var lastAcknowledgedFrameID: UInt16?

    init(
        sender: AppleMediaControlSending,
        keyBlob: Data,
        synchronizationSource: UInt32,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) throws {
        self.sender = sender
        encryptor = try AppleSRTCPEncryptor(keyBlob: keyBlob)
        self.synchronizationSource = synchronizationSource
        self.now = now
    }

    func sendNACKs(_ missingBySource: [UInt32: [UInt16]]) throws {
        for source in missingBySource.keys.sorted() {
            guard let missing = missingBySource[source] else { continue }
            let nack = AppleRTCP.genericNACK(
                sender: synchronizationSource,
                mediaSource: source,
                lostSequences: missing
            )
            guard !nack.isEmpty else { continue }
            try send(feedback: nack)
        }
    }

    func requestKeyFrame(for source: UInt32) throws {
        let feedback = lock.withFeedbackLock { () -> Data? in
            let currentTime = now()
            guard currentTime - lastKeyFrameRequest[source, default: -.infinity]
                    >= Self.minimumKeyFrameInterval else { return nil }
            lastKeyFrameRequest[source] = currentTime
            defer { feedbackSequence &+= 1 }
            return AppleRTCP.fullIntraRequest(
                sender: synchronizationSource,
                mediaSource: source,
                sequence: feedbackSequence
            ) + AppleRTCP.pictureLossIndication(
                sender: synchronizationSource,
                mediaSource: source
            ) + AppleRTCP.legacyFullIntraRequest(mediaSource: source)
        }
        guard let feedback else { return }
        try send(feedback: feedback)
    }

    func sendReceiverReport() throws {
        try send(packet: AppleRTCP.receiverReport(sender: synchronizationSource))
    }

    func sendReceiverReport(report: AppleRTPReceptionReport) throws {
        try send(packet: AppleRTCP.receiverReport(
            sender: synchronizationSource,
            report: report
        ))
    }

    func sendRateControl(mediaControlInfo: Data) throws {
        let packet = AppleRTCP.rateControl(
            sender: synchronizationSource,
            mediaControlInfo: mediaControlInfo
        )
        guard !packet.isEmpty else { throw AppleVideoFeedbackError.invalidRateControlPayload }
        try send(packet: packet)
    }

    func acknowledgeLongTermReference(frameID: UInt16) throws {
        let packet = lock.withFeedbackLock { () -> Data? in
            guard lastAcknowledgedFrameID != frameID else { return nil }
            lastAcknowledgedFrameID = frameID
            return AppleRTCP.longTermReferenceAcknowledgement(
                sender: synchronizationSource,
                frameID: frameID
            )
        }
        guard let packet else { return }
        try send(packet: packet)
    }

    private func send(feedback: Data) throws {
        let compound = AppleRTCP.compound(sender: synchronizationSource, feedback: feedback)
        try send(packet: compound)
    }

    private func send(packet: Data) throws {
        try sendLock.withFeedbackLock {
            try sender.sendControl(encryptor.protect(packet))
        }
    }
}

enum AppleVideoFeedbackError: Error, Equatable {
    case invalidRateControlPayload
}

private extension NSLock {
    func withFeedbackLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
