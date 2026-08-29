import CryptoKit
import Foundation
import XCTest
@testable import ScreenSharingProtocol

final class AppleSRTPTests: XCTestCase {
    func testKeyScheduleMatchesIndependentReference() throws {
        let schedule = try AppleSRTPKeySchedule(
            masterKey: Data(0..<32),
            masterSalt: Data(32..<46)
        )

        XCTAssertEqual(schedule.cipherKey.hex, "0e674e2db90fd074b7d117ff27482569aa7704a12a1a9bda69d33fcc7f96db40")
        XCTAssertEqual(schedule.authenticationKey.hex, "db98d1dedda0ab3e59c2048a813e92d6061c78c2")
        XCTAssertEqual(schedule.salt.hex, "2b6df10e137f6004526eda8495d9")
    }

    func testDecryptsAndAuthenticatesIndependentSRTPPacket() throws {
        let decryptor = try AppleSRTPDecryptor(keyBlob: Data(0..<46))
        let packet = try XCTUnwrap(
            Data(hex: "80e0000000000000112233448e12afed4336c640f79680aab77904")
        )

        let decrypted = try decryptor.decrypt(packet)

        XCTAssertEqual(decrypted.payload, Data("hello".utf8))
        XCTAssertEqual(decrypted.payloadType, 96)
        XCTAssertTrue(decrypted.marker)
        XCTAssertEqual(decrypted.synchronizationSource, 0x1122_3344)
    }

    func testRolloverAndLatePreviousRolloverPacketPreserveSourceState() throws {
        let blob = Data(0..<46)
        let source: UInt32 = 0x1122_3344
        let decryptor = try AppleSRTPDecryptor(keyBlob: blob)
        let finalBeforeRollover = try makeSRTPDatagram(
            payload: Data("before".utf8),
            sequence: .max,
            rollover: 0,
            source: source,
            keyBlob: blob
        )
        let firstAfterRollover = try makeSRTPDatagram(
            payload: Data("after".utf8),
            sequence: 0,
            rollover: 1,
            source: source,
            keyBlob: blob
        )
        let latePreviousRollover = try makeSRTPDatagram(
            payload: Data("late".utf8),
            sequence: 65_534,
            rollover: 0,
            source: source,
            keyBlob: blob
        )
        let nextCurrentRollover = try makeSRTPDatagram(
            payload: Data("next".utf8),
            sequence: 1,
            rollover: 1,
            source: source,
            keyBlob: blob
        )

        XCTAssertEqual(try decryptor.decrypt(finalBeforeRollover).payload, Data("before".utf8))
        XCTAssertEqual(try decryptor.decrypt(firstAfterRollover).payload, Data("after".utf8))
        XCTAssertEqual(try decryptor.decrypt(latePreviousRollover).payload, Data("late".utf8))
        XCTAssertEqual(try decryptor.decrypt(nextCurrentRollover).payload, Data("next".utf8))
    }

    func testAuthenticationFailureDoesNotAdvanceRolloverState() throws {
        let blob = Data(0..<46)
        let decryptor = try AppleSRTPDecryptor(keyBlob: blob)
        let valid = try makeSRTPDatagram(
            payload: Data("valid".utf8),
            sequence: .max,
            rollover: 0,
            source: 0x1122_3344,
            keyBlob: blob
        )
        var tampered = valid
        tampered[12] ^= 1

        XCTAssertThrowsError(try decryptor.decrypt(tampered)) {
            XCTAssertEqual($0 as? AppleSRTPError, .authenticationFailed)
        }
        XCTAssertEqual(try decryptor.decrypt(valid).payload, Data("valid".utf8))
    }

    func testDecryptSeparatesCSRCAndExtensionHeaderFromPayload() throws {
        let blob = Data(0..<46)
        let header = try XCTUnwrap(Data(hex: """
            916012340102030411223344aabbccdd
            9301000100251682
            """))
        let datagram = try makeSRTPDatagram(
            header: header,
            payload: Data("payload".utf8),
            rollover: 0,
            keyBlob: blob
        )

        let packet = try AppleSRTPDecryptor(keyBlob: blob).decrypt(datagram)

        XCTAssertEqual(packet.header, header)
        XCTAssertEqual(packet.payload, Data("payload".utf8))
        XCTAssertEqual(packet.sequenceNumber, 0x1234)
        XCTAssertEqual(packet.framePacketInfo, AppleRTPFramePacketInfo(
            totalPacketsPerFrame: 0x0025,
            frameSequenceNumber: 0x1682
        ))
    }

    func testRejectsAuthenticatedExtensionLengthBeyondPacket() throws {
        let blob = Data(0..<46)
        let header = try XCTUnwrap(Data(hex: """
            906012340102030411223344
            9301ffff
            """))
        let datagram = try makeSRTPDatagram(
            header: header,
            payload: Data([0xaa]),
            rollover: 0,
            keyBlob: blob
        )

        XCTAssertThrowsError(try AppleSRTPDecryptor(keyBlob: blob).decrypt(datagram)) {
            XCTAssertEqual($0 as? AppleSRTPError, .invalidPacket)
        }
    }

    func testRolloverStateIsIndependentForEachSynchronizationSource() throws {
        let blob = Data(0..<46)
        let decryptor = try AppleSRTPDecryptor(keyBlob: blob)
        let sourceA: UInt32 = 0x1111_1111
        let sourceB: UInt32 = 0x2222_2222

        for (sequence, rollover) in [
            (UInt16.max, UInt32(0)),
            (UInt16(0), UInt32(1)),
            (UInt16.max, UInt32(1)),
            (UInt16(0), UInt32(2)),
        ] {
            let datagram = try makeSRTPDatagram(
                payload: Data([UInt8(truncatingIfNeeded: rollover)]),
                sequence: sequence,
                rollover: rollover,
                source: sourceA,
                keyBlob: blob
            )
            XCTAssertEqual(try decryptor.decrypt(datagram).synchronizationSource, sourceA)
        }

        let sourceBPacket = try makeSRTPDatagram(
            payload: Data("source-b".utf8),
            sequence: 100,
            rollover: 0,
            source: sourceB,
            keyBlob: blob
        )
        XCTAssertEqual(try decryptor.decrypt(sourceBPacket).payload, Data("source-b".utf8))
    }

    func testProtectsIndependentSRTCPReferencePacket() throws {
        let encryptor = try AppleSRTCPEncryptor(keyBlob: Data(0..<46))
        let packet = try XCTUnwrap(
            Data(hex: "80c900011122334481cd00041122334455667788000a0005001e0000")
        )

        XCTAssertEqual(
            try encryptor.protect(packet).hex,
            "80c9000111223344ea6540af06680fabb3ce005aa192a9c2d9138ea18000000005039c4d56c23bf9e2ba"
        )
    }

    func testSRTCPIndexWrapsWithinThirtyOneBits() throws {
        let encryptor = try AppleSRTCPEncryptor(
            keyBlob: Data(0..<46),
            index: 0x7fff_ffff
        )
        let packet = try XCTUnwrap(Data(hex: "80c9000111223344"))

        let last = try encryptor.protect(packet)
        let wrapped = try encryptor.protect(packet)

        XCTAssertEqual(BigEndianWire.uint32(from: last, at: last.count - 14), 0xffff_ffff)
        XCTAssertEqual(BigEndianWire.uint32(from: wrapped, at: wrapped.count - 14), 0x8000_0000)
    }

    func testRejectsInvalidKeysPacketsAndAuthenticationTags() throws {
        XCTAssertThrowsError(try AppleSRTPDecryptor(keyBlob: Data(count: 45))) {
            XCTAssertEqual($0 as? AppleSRTPError, .invalidKeyBlob)
        }
        let encryptor = try AppleSRTCPEncryptor(keyBlob: Data(0..<46))
        XCTAssertThrowsError(try encryptor.protect(Data(repeating: 0, count: 7))) {
            XCTAssertEqual($0 as? AppleSRTPError, .invalidPacket)
        }
        let decryptor = try AppleSRTPDecryptor(keyBlob: Data(0..<46))
        XCTAssertThrowsError(try decryptor.decrypt(Data(repeating: 0, count: 21))) {
            XCTAssertEqual($0 as? AppleSRTPError, .invalidPacket)
        }
    }

    func testReadsAppleRTPHeaderExtensionFields() {
        let ltrHeader = Data([
            0x90, 0x60, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
            0x93, 0x11, 0, 1,
            0x00, 0x25, 0x16, 0x82,
        ])
        let ltrPacket = rtpPacket(header: ltrHeader)

        var ordinaryHeader = ltrHeader
        ordinaryHeader[13] = 0x01

        XCTAssertTrue(ltrPacket.isLongTermReferenceFrame)
        XCTAssertFalse(rtpPacket(header: ordinaryHeader).isLongTermReferenceFrame)
        XCTAssertEqual(ltrPacket.framePacketInfo, AppleRTPFramePacketInfo(
            totalPacketsPerFrame: 0x0025,
            frameSequenceNumber: 0x1682
        ))
    }

    func testRefreshBitDoesNotRequestLongTermReferenceAcknowledgement() {
        let refreshPacket = rtpPacket(header: Data([
            0x90, 0x60, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
            0x93, 0x21, 0, 1,
            0x00, 0x25, 0x16, 0x82,
        ]))

        XCTAssertFalse(refreshPacket.isLongTermReferenceFrame)
    }

    func testRejectsAbsentOrTruncatedFramePacketInfo() {
        let absent = rtpPacket(header: Data([
            0x90, 0x60, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
            0x93, 0x10, 0, 1,
            0x00, 0x25, 0x16, 0x82,
        ]))
        let truncated = rtpPacket(header: Data([
            0x90, 0x60, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
            0x93, 0x01, 0, 1,
        ]))

        XCTAssertNil(absent.framePacketInfo)
        XCTAssertNil(truncated.framePacketInfo)
    }

    private func makeSRTPDatagram(
        payload: Data,
        sequence: UInt16,
        rollover: UInt32,
        source: UInt32,
        keyBlob: Data
    ) throws -> Data {
        var header = Data([0x80, 0x60])
        BigEndianWire.append(sequence, to: &header)
        BigEndianWire.append(UInt32(0x0102_0304), to: &header)
        BigEndianWire.append(source, to: &header)
        return try makeSRTPDatagram(
            header: header,
            payload: payload,
            rollover: rollover,
            keyBlob: keyBlob
        )
    }

    private func makeSRTPDatagram(
        header: Data,
        payload: Data,
        rollover: UInt32,
        keyBlob: Data
    ) throws -> Data {
        let keys = try AppleSRTPKeySchedule(blob: keyBlob)
        let sequence = try XCTUnwrap(BigEndianWire.uint16(from: header, at: 2))
        let source = try XCTUnwrap(BigEndianWire.uint32(from: header, at: 8))
        let index = UInt64(rollover) << 16 | UInt64(sequence)
        let ciphertext = try AppleProtocolAES.cryptCTR(
            payload,
            key: keys.cipherKey,
            initializationVector: srtpInitializationVector(
                salt: keys.salt,
                source: source,
                index: index
            )
        )
        var datagram = header
        datagram.append(ciphertext)
        var authenticated = datagram
        BigEndianWire.append(rollover, to: &authenticated)
        let code = HMAC<Insecure.SHA1>.authenticationCode(
            for: authenticated,
            using: SymmetricKey(data: keys.authenticationKey)
        )
        datagram.append(contentsOf: code.prefix(10))
        return datagram
    }

    private func srtpInitializationVector(
        salt: Data,
        source: UInt32,
        index: UInt64
    ) -> Data {
        var vector = salt + Data(repeating: 0, count: 2)
        for offset in 0..<4 {
            vector[4 + offset] ^= UInt8(truncatingIfNeeded: source >> UInt32(24 - offset * 8))
        }
        for offset in 0..<6 {
            vector[8 + offset] ^= UInt8(truncatingIfNeeded: index >> UInt64(40 - offset * 8))
        }
        return vector
    }

    private func rtpPacket(header: Data) -> AppleRTPPacket {
        AppleRTPPacket(
            header: header,
            payload: Data(),
            sequenceNumber: 1,
            timestamp: 2,
            synchronizationSource: 3,
            payloadType: 96,
            marker: false
        )
    }
}

private extension Data {
    init?(hex: String) {
        let hex = hex.filter { !$0.isWhitespace }
        guard hex.count.isMultiple(of: 2) else { return nil }
        self.init()
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<end], radix: 16) else { return nil }
            append(byte)
            index = end
        }
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
