import Foundation
import enum ScreenSharingProtocol.AppleRTCP
import struct ScreenSharingProtocol.AppleRTPReceptionReport

final class AppleVideoFeedbackController: @unchecked Sendable {
    private let lock = NSLock()
    private let sendLock = NSLock()
    private let sender: AppleMediaControlSending
    private let encryptor: AppleSRTCPEncryptor
    private let synchronizationSource: UInt32
    private var feedbackSequence: UInt8 = 0

    init(
        sender: AppleMediaControlSending,
        keyBlob: Data,
        synchronizationSource: UInt32
    ) throws {
        self.sender = sender
        encryptor = try AppleSRTCPEncryptor(keyBlob: keyBlob)
        self.synchronizationSource = synchronizationSource
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
        let feedback = lock.withFeedbackLock { () -> Data in
            defer { feedbackSequence &+= 1 }
            return AppleRTCP.fullIntraRequest(
                sender: synchronizationSource,
                mediaSource: source,
                sequence: feedbackSequence
            )
        }
        try send(packet: feedback)
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

    func sendFrameLossFeedback(
        mediaSource: UInt32,
        rtpTimestamp: UInt32,
        packedLoss: UInt16,
        framePacketCount: UInt8,
        frameLostPacketCount: UInt8
    ) throws {
        try send(packet: AppleRTCP.frameLossFeedback(
            sender: synchronizationSource,
            mediaSource: mediaSource,
            rtpTimestamp: rtpTimestamp,
            packedLoss: packedLoss,
            framePacketCount: framePacketCount,
            frameLostPacketCount: frameLostPacketCount
        ))
    }

    func acknowledgeLongTermReference(
        decodingOrderNumber: UInt16
    ) throws {
        try send(packet: AppleRTCP.longTermReferenceAcknowledgement(
            sender: synchronizationSource,
            decodingOrderNumber: decodingOrderNumber
        ))
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
