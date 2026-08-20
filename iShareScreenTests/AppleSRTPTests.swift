import XCTest
@testable import iShareScreen

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
        let blob = Data(0..<46)
        let decryptor = try AppleSRTPDecryptor(keyBlob: blob)
        let packet = try XCTUnwrap(Data(hex: "80e0000000000000112233448e12afed4336c640f79680aab77904"))

        let decrypted = try decryptor.decrypt(packet)

        XCTAssertEqual(decrypted.payload, Data("hello".utf8))
        XCTAssertEqual(decrypted.payloadType, 96)
        XCTAssertTrue(decrypted.marker)
        XCTAssertEqual(decrypted.synchronizationSource, 0x1122_3344)
    }

    func testRejectsTamperedSRTPPacket() throws {
        let decryptor = try AppleSRTPDecryptor(keyBlob: Data(0..<46))
        var packet = try XCTUnwrap(Data(hex: "80e0000000000000112233448e12afed4336c640f79680aab77904"))
        packet[12] ^= 1
        XCTAssertThrowsError(try decryptor.decrypt(packet)) { error in
            XCTAssertEqual(error as? AppleSRTPError, .authenticationFailed)
        }
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

    func testSRTCPRejectsShortPacket() throws {
        let encryptor = try AppleSRTCPEncryptor(keyBlob: Data(0..<46))
        XCTAssertThrowsError(try encryptor.protect(Data(repeating: 0, count: 7))) { error in
            XCTAssertEqual(error as? AppleSRTPError, .invalidPacket)
        }
    }
}

private extension Data {
    init?(hex: String) {
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
